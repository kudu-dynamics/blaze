{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Blaze.Solver2 where

import Blaze.Prelude hiding (zero)
import qualified Prelude as P

import qualified Blaze.Types.Pil as Pil
import Blaze.Types.Pil ( Expression( Expression )
                       , Stmt
                       , PilVar
                       , TypeEnv(TypeEnv)
                       , HasLeft
                       , HasRight
                       )
import qualified Data.HashMap.Strict as HashMap
import qualified Data.HashSet as HashSet
import Blaze.Types.Solver2
import qualified Blaze.Pil.Analysis as A
import Data.SBV.Tools.Overflow (ArithOverflow, bvAddO)
import qualified Data.SBV.Trans as SBV
import qualified Data.SBV.Trans.Control as SBV
import qualified Data.Text as Text
import qualified Binja.Function as Func
import Data.SBV.Dynamic as D hiding (Solver)
import qualified Blaze.Types.Pil.Checker as Ch
import Blaze.Types.Pil.Checker (DeepSymType, SymInfo(SymInfo), InfoExpression(InfoExpression))
--import Data.SBV.Core.Data (SBV(SBV, unSBV))
import Data.SBV.Internals (SBV(SBV))


pilVarName :: PilVar -> Text
pilVarName pv = pv ^. Pil.symbol
  <> maybe "" (("@"<>) . view (Pil.func . Func.name)) mCtx
  <> maybe "" (("."<>) . show . f . view Pil.ctxIndex) mCtx
  where
    f (Pil.CtxIndex n) = n
    mCtx :: Maybe Pil.Ctx
    mCtx = pv ^. Pil.ctx


-- | convert a DeepSymType to an SBV Kind
-- any un-inferred Sign types resolve to False
deepSymTypeToKind :: DeepSymType -> Solver Kind
deepSymTypeToKind t = case t of
  Ch.DSVar v -> err $ "Can't convert DSVar " <> show v
  Ch.DSRecursive _s pt -> deepSymTypeToKind (Ch.DSType pt)
                          -- ignore recursion, and hope for the best

  Ch.DSType pt -> case pt of
    Ch.TArray _alen _etype -> err "Can't handdle Array"
    Ch.TBool -> return KBool
    Ch.TChar -> return $ KBounded False 8
    Ch.TInt bwt st -> KBounded <$> (getSigned st <|> pure False) <*> getBitWidth bwt
    Ch.TFloat _ -> return KDouble
                   -- SBV only has float or double, so we'll just pick double

    Ch.TBitVector bwt -> KBounded <$> pure False <*> getBitWidth bwt
    Ch.TPointer bwt _pt -> KBounded <$> pure False <*> getBitWidth bwt
    Ch.TRecord _ -> err $ "Can't handle Record type"
    Ch.TBottom s -> err $ "TBottom " <> show s
    Ch.TFunction _ _ -> err "Can't handle Function type"

    -- these all should be handled as nested in above type conversions
    Ch.TVBitWidth _ -> err "Out of place TVBitWidth"
    Ch.TVLength _ -> err "Out of place TVLength"
    Ch.TVSign _ -> err "Out of place TVSign"
  where
    getBitWidth (Ch.DSType (Ch.TVBitWidth bw)) = return $ fromIntegral bw
    getBitWidth badbw = err $ "Can't get bitwidth of: " <> show badbw

    getSigned (Ch.DSType (Ch.TVSign s)) = return s
    getSigned bads = err $ "Can't get signed of: " <> show bads

    err :: forall a. Text -> Solver a
    err msg = throwError . DeepSymTypeConversionError t $ msg

makeSymVar :: Maybe Text -> Kind -> Solver SVal
makeSymVar nm k = SBV.symbolicEnv >>= liftIO . D.svMkSymVar Nothing k (cs <$> nm)

makeSymVarOfType :: Maybe Text -> DeepSymType -> Solver SVal
makeSymVarOfType nm dst = deepSymTypeToKind dst >>= makeSymVar nm


declarePilVars :: Solver ()
declarePilVars = ask >>= mapM_ f . HashMap.toList . typeEnv
  where
    f (pv, dst) = do
      sval <- makeSymVarOfType (Just nm) dst
      varNames %= HashMap.insert pv nm
      varMap %= HashMap.insert pv sval
      where
        nm = pilVarName pv

constInt :: Bits -> Integer -> SVal
constInt w = svInteger (KBounded True $ fromIntegral w)

constWord :: Bits -> Integer -> SVal
constWord w = svInteger (KBounded False $ fromIntegral w)

-- | requires: targetWidth >= bv
--           : kindOf bv is bounded
zeroExtend :: Bits -> SVal -> SVal
zeroExtend targetWidth bv = case kindOf bv of
  (KBounded s w)
    | tw == w -> bv
    | tw > w -> svJoin ext bv
    | otherwise -> P.error "zeroExtend: target width less than bitvec width"
    where
      ext = svInteger (KBounded s $ fromIntegral targetWidth - w) 0
  _ -> P.error "zeroExtend: arg not bitvec"
  where
    tw = fromIntegral targetWidth

-- | most significant bit
-- requires: kindOf bv is Bounded
--         : width bv > 0
msb :: SVal -> SVal
msb bv = case kindOf bv of
  (KBounded _ w)
    | w == 0 -> P.error "msb: bv has zero width"
    | otherwise -> svTestBit bv (w - 1)
  _ -> P.error "msb: bv must be Bounded kind"

-- | requires: targetWidth >= bv
--           : kindOf bv is bounded
--           : width bv > 0
signExtend :: Bits -> SVal -> SVal
signExtend targetWidth bv = case kindOf bv of
  (KBounded s w)
    | tw == w -> bv
    | tw > w -> svJoin ext bv
    | otherwise -> P.error "signExtend: target width less than bitvec width"
    where
      tw = fromIntegral targetWidth
      zero = svInteger (KBounded s $ fromIntegral targetWidth - w) 0
      ones = svNot zero
      ext  = svIte (msb bv) ones zero
  _ -> P.error "signExtend: bv must be Bounded kind"

-- | Extends b to match a's width.
-- | requires: width a >= width b
--           : kindOf a, b are bounded
--           : widths a, b > 0
matchBoundedWidth :: SVal -> SVal -> SVal
matchBoundedWidth a b = case (kindOf a, kindOf b) of
  (KBounded s w1, KBounded _ w2)
    | w1 == w2 -> b
    | otherwise -> if s then signExtend w1' b else zeroExtend w1' b
    where
      w1' = fromIntegral w1
  _ -> P.error "matchBoundedWidth: a and b must be kind Bounded"

-- | Matches second to first bounded integral sign
-- error if either not bounded.
matchSign :: SVal -> SVal -> SVal
matchSign a b = case (kindOf a, kindOf b) of
  (KBounded s1 _, KBounded s2 _)
    | s1 == s2 -> b
    | otherwise -> if s1 then svSign b else svUnsign b
  _ -> P.error "matchSign: a and b must be kind Bounded"


pilAdd :: SVal -> SVal -> SVal
pilAdd a b = a `svPlus` b'
  where
    b' = matchSign a (matchBoundedWidth a b)

-- binOpFirstArgMatchesReturnType :: (SVal -> SVal -> SVal) -> SVal -> SVal -> Solver

-- -- add :: SVal -> SVal -> Symbolic SVal

toSBool' :: SVal -> SBool
toSBool' x = case kindOf x of
  KBool -> SBV x
  _ -> P.error "toSBool: x is not KBool kind"

toSBool :: SVal -> Solver SBool
toSBool x = guardBool x >> return (SBV x)

constrain :: SVal -> Solver ()
constrain x = toSBool x >>= SBV.constrain

-- constrainSVal :: SVal -> Solver

newSymVar :: Text -> Kind -> Solver SVal
newSymVar name k = SBV.symbolicEnv >>= liftIO . D.svMkSymVar Nothing k (Just $ cs name)
 
--   PTInt w -> SBV.symbolicEnv >>= liftIO . D.svMkSymVar Nothing (D.KBounded True w) (Just . cs $ nm)
--   PTWord w -> SBV.symbolicEnv >>= liftIO . D.svMkSymVar Nothing (D.KBounded False w) (Just . cs $ nm)

test :: Solver ()
test = do
  a <- newSymVar "a" (KBounded False 32)
  b <- newSymVar "b" (KBounded False 20)
  c <- newSymVar "c" (KBounded False 32)
  let r = constWord 32 88
  constrain $ c `svEqual` r
  let b' = zeroExtend 32 b
  constrain $ a `svLessThan` b'
  constrain $ svEqual c (a `svPlus` b')


test2 :: SymbolicT (ExceptT () IO) ()
test2 = do
  SBV.constrain . toSBool' $ constInt 32 99 `svEqual` constInt 32 99
  return ()

-------------------------------

guardBool :: SVal -> Solver ()
guardBool x = case k of
  KBool -> return ()
  _ -> throwError $ GuardError "guardBool" [k] "Not Bool"
  where
    k = kindOf x

guardIntegral :: HasKind a => a -> Solver ()
guardIntegral x = case k of
  KBounded _ _ -> return ()
  _ -> throwError $ GuardError "guardIntegral" [k] "Not integral"
  where
    k = kindOf x

guardIntegralFirstWidthNotSmaller :: SVal -> SVal -> Solver ()
guardIntegralFirstWidthNotSmaller x y = case (kx, ky) of
  (KBounded _ w1, KBounded _ w2)
    | w1 >= w2 -> return ()
    | otherwise -> throwError $ GuardError "guardIntegralFirstWidthNotSmaller"
                   [kx, ky]
                   "Second arg width is greater than first"
  _ -> throwError $ GuardError "guardIntegralFirstWidthNotSmaller"
       [kx, ky]
       "Both must be KBounded"
  where
    kx = kindOf x
    ky = kindOf y

-- | Creates SVal that represents expression.
--   This type of InfoExpression is in a TypeReport
solveExpr :: DSTExpression -> Solver SVal
-- solveExpr (Ch.InfoExpression ((Ch.SymInfo _ xsym), Nothing) _) = \
--   solverError $ "No type for sym " <> show xsym
solveExpr (Ch.InfoExpression ((Ch.SymInfo sz xsym), mdst) op) = case op of
--   Pil.ADC x -> integralBinOpFirstArgIsReturn Nothing True x
  Pil.ADD x -> integralBinOpFirstArgIsReturn x pilAdd

--   -- should this be unsigned ret because overflow is always positive?
--   Pil.ADD_OVERFLOW x -> integralBinOpFirstArgIsReturn Nothing True x

--   Pil.AND x -> bitVectorBinOp x

--   --   shift right...?
--   Pil.ASR x -> integralFirstArgIsReturn x

-- --   BOOL_TO_INT _ -> 

--   -- TODO get most general type for this and args:
--   Pil.CALL _ -> return [ (r, CSType $ TBitVector sz') ]
  
--   Pil.CEIL x -> floatUnOp x
--   Pil.CMP_E x -> integralBinOpReturnsBool x
--   Pil.CMP_NE x -> integralBinOpReturnsBool x

--   Pil.CMP_SGE x -> signedBinOpReturnsBool True x
--   Pil.CMP_SGT x -> signedBinOpReturnsBool True x
--   Pil.CMP_SLE x -> signedBinOpReturnsBool True x
--   Pil.CMP_SLT x -> signedBinOpReturnsBool True x
--   Pil.CMP_UGE x -> signedBinOpReturnsBool False x
--   Pil.CMP_UGT x -> signedBinOpReturnsBool False x
--   Pil.CMP_ULE x -> signedBinOpReturnsBool False x
--   Pil.CMP_ULT x -> signedBinOpReturnsBool False x
  Pil.CONST x -> do
    dst <- getDst
    k <- deepSymTypeToKind dst
    guardIntegral k
    return . svInteger k . fromIntegral $ x ^. Pil.constant

--   Pil.CONST_PTR _ -> retPointer
--   Pil.ConstStr x -> return [(r, CSType $ TArray
--                                 ( CSType . TVLength . fromIntegral . Text.length
--                                   $ x ^. Pil.value )
--                                 ( CSType TChar ))]
--   Pil.DIVS x -> integralBinOpFirstArgIsReturn (Just True) False x
--   Pil.DIVS_DP x -> integralBinOpDP (Just True) x
--   Pil.DIVU x -> integralBinOpFirstArgIsReturn (Just False) False x
--   Pil.DIVU_DP x -> integralBinOpDP (Just False) x
--   Pil.FABS x -> floatUnOp x
--   Pil.FADD x -> floatBinOp x
--   Pil.FCMP_E x -> floatBinOpReturnsBool x
--   Pil.FCMP_GE x -> floatBinOpReturnsBool x
--   Pil.FCMP_GT x -> floatBinOpReturnsBool x
--   Pil.FCMP_LE x -> floatBinOpReturnsBool x
--   Pil.FCMP_LT x -> floatBinOpReturnsBool x
--   Pil.FCMP_O x -> floatBinOpReturnsBool x
--   Pil.FCMP_NE x -> floatBinOpReturnsBool x
--   Pil.FCMP_UO x -> floatBinOpReturnsBool x
--   Pil.FDIV x -> floatBinOp x

--   Pil.FIELD_ADDR x -> do
--     fieldType <- CSVar <$> newSym
--     let recType = CSType . TRecord . HashMap.fromList $
--           -- for now, assuming all offsets are positive...
--           [ (byteOffsetToBitOffset $ x ^. Pil.offset, fieldType) ]
--     return [ ( r, CSType $ TPointer sz' fieldType )
--            , ( x ^. Pil.baseAddr . info . sym, CSType $ TPointer sz' recType )
--            ]

--   Pil.FLOAT_CONST _ -> retFloat

-- -- TODO: should there be a link between sz of bitvec and sz of float?
--   Pil.FLOAT_CONV x -> do
--     bvWidth <- CSVar <$> newSym
--     return [ ( x ^. Pil.src . info . sym, CSType $ TBitVector bvWidth )
--            , ( r, CSType $ TFloat sz' )
--            ]
--   Pil.FLOAT_TO_INT x -> floatToInt x
--   Pil.FLOOR x -> floatUnOp x
--   Pil.FMUL x -> floatBinOp x
--   Pil.FNEG x -> floatUnOp x
--   Pil.FSQRT x -> floatUnOp x
--   Pil.FTRUNC x -> floatUnOp x
--   Pil.FSUB x -> floatBinOp x

-- --   what does IMPORT do?
-- --   assuming it just casts an Int to a pointer
--   Pil.IMPORT _ -> retPointer

--   Pil.INT_TO_FLOAT x -> intToFloat x

--   Pil.LOAD x -> do
--     ptrWidth <- CSVar <$> newSym
--     ptrType <- CSVar <$> newSym
--     return [ ( x ^. Pil.src . info . sym, CSType $ TPointer ptrWidth ptrType )
--            , ( r, ptrType )
--            , ( r, CSType $ TBitVector sz' )
--            ]

--   -- should _x have any influence on the type of r?
--   Pil.LOW_PART _x -> return [(r, CSType $ TBitVector sz')]

--   Pil.LSL x -> integralFirstArgIsReturn x
--   Pil.LSR x -> integralFirstArgIsReturn x
--   Pil.MODS x -> integralBinOpFirstArgIsReturn (Just True) False x
--   Pil.MODS_DP x -> integralBinOpDP (Just True) x
--   Pil.MODU x -> integralBinOpFirstArgIsReturn (Just False) False x
--   Pil.MODU_DP x -> integralBinOpDP (Just False) x
--   Pil.MUL x -> integralBinOpFirstArgIsReturn Nothing True x
--   Pil.MULS_DP x -> integralBinOpDP (Just True) x
--   Pil.MULU_DP x -> integralBinOpDP (Just False) x
--   Pil.NEG x -> integralUnOp (Just True) x
--   Pil.NOT x -> bitVectorUnOp x
--   Pil.OR x -> bitVectorBinOp x
--   Pil.RLC x -> integralFirstArgIsReturn x
--   Pil.ROL x -> integralFirstArgIsReturn x
--   Pil.ROR x -> integralFirstArgIsReturn x
--   Pil.ROUND_TO_INT x -> floatToInt x
--   Pil.RRC x -> integralFirstArgIsReturn x
--   Pil.SBB x -> signedBinOpReturnsBool True x
-- --   -- STORAGE _ -> unknown
-- --   StrCmp _ -> intRet
-- --   StrNCmp _ -> intRet
-- --   MemCmp _ -> intRet

--   -- should this somehow be linked to the type of the stack var?
--   -- its type could change every Store.
--   Pil.STACK_LOCAL_ADDR _ -> retPointer

--   Pil.SUB x -> integralBinOpFirstArgIsReturn (Just True) True x
--   Pil.SX x -> integralExtendOp x

-- --   TEST_BIT _ -> boolRet -- ? tests if bit in int is on or off
--   Pil.UNIMPL _ -> return [ (r, CSType $ TBitVector sz' ) ]
--   Pil.UPDATE_VAR x -> do
--     v <- lookupVarSym $ x ^. Pil.dest
--     -- How should src and dest be related?
--     -- Can't express that `offset + width(src) == width(dest)`
--     --  without `+` and `==` as type level operators.
--     return [ (r, CSVar v) ]

--   Pil.VAR x -> do
--     v <- lookupVarSym $ x ^. Pil.src
--     return [ (r, CSVar v)
--            , (v, CSType $ TBitVector sz')
--            ]
--   Pil.VAR_FIELD _ ->
--     -- TODO: can we know anything about src PilVar by looking at offset + result size?
--     return [ (r, CSType $ TBitVector sz') ]

--   -- binja is wrong about the size of VarSplit.
--   Pil.VAR_SPLIT x -> do
--     low <- lookupVarSym $ x ^. Pil.low
--     high <- lookupVarSym $ x ^. Pil.high
--     return [ (r, CSType $ TBitVector sz2x')
--            , (low, CSType $ TBitVector sz')
--            , (high, CSType $ TBitVector sz')
--            ]

--   Pil.XOR x -> bitVectorBinOp x
--   Pil.ZX x -> integralExtendOp x
-- --   -- _ -> unknown

-- --   Extract _ -> bitvecRet
--   _ -> P.error . show $ op'
  _ -> throwError . ErrorMessage $ "unhandled PIL op: "
       <> Text.takeWhile (/= ' ') (show op)
  where
    fallbackAsFreeVar :: Solver SVal
    fallbackAsFreeVar = case mdst of
      Nothing -> throwError . ExprError xsym . ErrorMessage $ "missing DeepSymType"
      Just dst -> catchError (makeSymVarOfType Nothing dst) $ \e ->
          throwError $ ExprError xsym e

    getDst :: Solver DeepSymType
    getDst = maybe e return mdst
      where e = throwError . ErrorMessage $ "missing DeepSymType"

    warn :: SolverError -> Solver ()
    warn e = errors %= (e :)

    catchFallbackAndWarn :: Solver SVal -> Solver SVal
    catchFallbackAndWarn m = catchError m $ \e -> do  
      si <- use currentStmtIndex
      warn $ StmtError si e
      fallbackAsFreeVar
      
    
    -- assumes first arg width >= second arg width
    integralBinOpFirstArgIsReturn :: ( Pil.HasLeft x DSTExpression
                                     , Pil.HasRight x DSTExpression)
                                  => x -> (SVal -> SVal -> SVal) -> Solver SVal
    integralBinOpFirstArgIsReturn x f = catchFallbackAndWarn $ do
      lx <- solveExpr (x ^. Pil.left)
      rx <- solveExpr (x ^. Pil.right)
      guardIntegralFirstWidthNotSmaller lx rx
      return $ f lx rx
      

