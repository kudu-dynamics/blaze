{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Blaze.Solver2
  ( module Blaze.Solver2
  , module Blaze.Types.Solver2
  , module Exports ) where

import Blaze.Prelude hiding (zero, natVal, isSigned)
import qualified Prelude as P
import qualified Blaze.Types.Pil as Pil
import Blaze.Types.Pil ( Expression
                       , PilVar
                       , HasLeft
                       , HasRight
                       , HasCarry
                       , Statement
                       )
import qualified Data.HashMap.Strict as HashMap
import qualified Blaze.Pil.Analysis as Analysis
import Blaze.Types.Solver2
import Data.SBV.Tools.Overflow (bvAddO)
import qualified Data.SBV.Trans as Exports (z3, cvc4)
import qualified Data.SBV.Trans as SBV
import Data.SBV.Trans ( (.==)
                      , (./=)
                      , (.>)
                      , (.>=)
                      , (.<)
                      , (.<=)
                      , (.||)
                      , (.~|)
                      )
import qualified Data.Text as Text
import qualified Binja.Function as Func
import Binja.Function (Function)
import Blaze.Types.Path.AlgaPath (AlgaPath)
import qualified Blaze.Pil.Path as Path
import Data.SBV.Dynamic as D hiding (Solver)
import qualified Blaze.Types.Pil.Checker as Ch
import qualified Blaze.Pil.Checker as Ch
import Blaze.Types.Pil.Checker ( DeepSymType )
import Data.SBV.Internals (SBV(SBV), unSBV)


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
    err = throwError . DeepSymTypeConversionError t

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

constFloat :: Double -> SVal
constFloat = svDouble

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

signExtendSVal :: SVal -> SVal -> SVal
signExtendSVal tw bv = case kindOf bv of
  (KBounded _s w) -> svIte (tw `svGreaterEq` (constWord 32 $ toInteger w)) (svJoin ext bv) bv
    where
      -- subtract an additional 1 off since we are zero inclusive in createExtendBuf
      extWidth = tw `svMinus` (constWord 32 $ toInteger w) `svMinus` constWord 32 1
      zeros = buf
      ones = svNot buf
      ext = svIte (msb bv) ones zeros
      buf = createExtendBuf extWidth
      createExtendBuf :: SVal -> SVal
      createExtendBuf width = svIte (width `svEqual` constWord 32 0) 
                                      (constInt 1 0) 
                                      $ svJoin (createExtendBuf $ width `svMinus` constWord 32 1) $ constInt 1 0
  _ -> P.error "signExtend: bv must be Bounded kind"

zeroExtendSVal :: SVal -> SVal -> SVal
zeroExtendSVal tw bv = case kindOf bv of
  (KBounded _s w) -> svIte (tw `svGreaterEq` (constWord 32 $ toInteger w)) (svJoin buf bv) bv
    where
      extWidth = tw `svMinus` (constWord 32 $ toInteger w) `svMinus` constWord 32 1
      buf = createExtendBuf extWidth
      createExtendBuf :: SVal -> SVal
      createExtendBuf width = svIte (width `svEqual` constWord 32 0)
                                      (constWord 1 0)
                                      $ svJoin (createExtendBuf $ width `svMinus` constWord 32 1) $ constWord 1 0
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

pilCmpE :: SVal -> SVal -> SVal
pilCmpE a b = case (kindOf a, kindOf b) of
  (KBounded _ w0, KBounded _ _) -> svGreaterEq (constWord (Bits w0') 0) absDiff
    where
      w0' = fromIntegral w0
      absDiff = svAbs diff'
      diff' = (a `svMinus` b)
  _ -> P.error "pilCmpE: both args should be KBounded kind"

pilSub :: SVal -> SVal -> SVal
pilSub a b = a `svMinus` b'
  where
    b' = matchSign a (matchBoundedWidth a b)

pilCeil :: SVal -> SVal
pilCeil x = case kindOf x of
  KDouble -> unSBV . SBV.fpRoundToIntegral SBV.sRoundTowardPositive $ toSFloat' x
  _ -> P.error "pilCeil: x is not a KDouble"

pilFloor :: SVal -> SVal
pilFloor x = case kindOf x of
  KDouble -> unSBV . SBV.fpRoundToIntegral SBV.sRoundTowardNegative $ toSFloat' x
  _ -> P.error "pilFloor: x is not a KDouble"

pilFAdd :: SVal -> SVal -> SVal
pilFAdd a b = case (kindOf a, kindOf b) of
  (KDouble, KDouble) -> unSBV $ SBV.fpAdd 
                                SBV.sRoundNearestTiesToAway
                                (toSFloat' a)
                                (toSFloat' b)
  _ -> P.error "pilFAdd: one or both arguments are not KDouble"

pilFDiv :: SVal -> SVal -> SVal
pilFDiv a b = case (kindOf a, kindOf b) of
  (KDouble, KDouble) -> unSBV $ SBV.fpDiv 
                                SBV.sRoundNearestTiesToAway
                                (toSFloat' a)
                                (toSFloat' b)
  _ -> P.error "pilFDiv: one or both arguments are not KDouble"

pilRol :: SVal -> SVal -> SVal
pilRol a b = a `svRotateLeft` b

isSigned :: SVal -> Bool
isSigned x = case kindOf x of
  KBounded s _ -> s
  k            -> P.error $ "isSigned expected KBounded, got " <> show k

sSignedShiftArithRight :: SVal -> SVal -> SVal
sSignedShiftArithRight x i
  | isSigned i = error "sSignedShiftArithRight: shift amount should be unsigned"
  | isSigned x = svShiftRight x i
  | True       = svIte (msb x)
                       (svNot (svShiftRight (svNot x) i))
                       (svShiftRight x i)

-- TODO: convert SVals to unsigned.
-- the svJoin gets messed up if these are signed
updateBitVec :: BitOffset -> SVal -> SVal -> SVal
updateBitVec boff src dest = case (kindOf dest, kindOf src) of
  (KBounded destSign wdest, KBounded _ wsrc)
    | wsrc + off > wdest -> P.error "updateBitVec: src width + offset must be less than dest width"
    | otherwise -> bool svUnsign svSign destSign
                   $ destHighPart `svJoin` src' `svJoin` destLowPart
    where
      dest' = svUnsign dest
      src' = svUnsign src
      destHighPart = highPart (fromIntegral $ wdest - (off + wsrc)) dest'
      destLowPart = lowPart (fromIntegral boff) dest'
      off = fromIntegral boff
  _ -> P.error "updateBitVec: both args must be KBounded"
  

-- TODO: guard that n is greater than 0
-- and that w is big enough
lowPart :: Bits -> SVal -> SVal
lowPart n src = case kindOf src of
  KBounded _ _w -> svExtract (fromIntegral n - 1) 0 src
  _ -> P.error "lowPart: src must be KBounded"

-- TODO: guard that n is greater than 0
-- and that w is big enough
highPart :: Bits -> SVal -> SVal
highPart n src = case kindOf src of
  KBounded _ w -> svExtract (w - 1) (w - fromIntegral n) src
  _ -> P.error "lowPart: src must be KBounded"


-- with carry works like regular rotate with carry appended to the end
rotateWithCarry :: (SVal -> SVal -> SVal) -> SVal -> SVal -> SVal -> SVal
rotateWithCarry f src rot c = case kindOf src of
  KBounded _ w -> svExtract w 1 $ f (svJoin src c) rot
  _ -> P.error "rotateWithCarry: src is not KBounded"

toSFloat :: SVal -> Solver SBV.SDouble
toSFloat x = guardFloat x >> return (SBV x)

toSFloat' :: SVal -> SBV.SDouble
toSFloat' x = case kindOf x of
  KDouble -> SBV x
  _ -> P.error "toSFloat: x is not KDouble kind"

toSBool' :: SVal -> SBool
toSBool' x = case kindOf x of
  KBool -> SBV x
  _ -> P.error "toSBool: x is not KBool kind"

toSBool :: SVal -> Solver SBool
toSBool x = guardBool x >> return (SBV x)

-- converts bool to 0 or 1 integral of Kind k
boolToInt :: Kind -> SVal -> Solver SVal
boolToInt (KBounded s w) b = do
  guardBool b
  return $ svIte b (svInteger (KBounded s w) 1) (svInteger (KBounded s w) 0)
boolToInt t _ = throwError . ErrorMessage $ "boolToInt expected KBounded, got " <> show t

constrain :: SVal -> Solver ()
constrain x = toSBool x >>= SBV.constrain

newSymVar :: Text -> Kind -> Solver SVal
newSymVar name' k = SBV.symbolicEnv >>= liftIO . D.svMkSymVar Nothing k (Just $ cs name')

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

guardBool :: HasKind a => a -> Solver ()
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

guardFloat :: HasKind a => a -> Solver ()
guardFloat x = case k of
  KDouble -> return ()
  _ -> throwError $ GuardError "guardFloat" [k] "Not Double"
  where
    k = kindOf x

guardIntegralFirstWidthNotSmaller :: (HasKind a, HasKind b)
                                  => a -> b -> Solver ()
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

guardSameKind :: (HasKind a, HasKind b) => a -> b -> Solver ()
guardSameKind x y = case kindOf x == kindOf y of
  True -> return ()
  _ -> throwError . ErrorMessage $ "guardSameKind: Not same kind"

lookupVarSym :: PilVar -> Solver SVal
lookupVarSym pv = do
  vm <- use varMap
  maybe err return $ HashMap.lookup pv vm
  where
    err = throwError . ErrorMessage
          $ "lookupVarSym failed for var '" <> pilVarName pv <> "'"

bitsToOperationSize :: Bits -> Pil.OperationSize
bitsToOperationSize = Pil.OperationSize . (`div` 8) . fromIntegral

dstToExpr :: DSTExpression -> Expression
dstToExpr (Ch.InfoExpression (info, _) op) = Pil.Expression (bitsToOperationSize $ info ^. Ch.size) $ dstToExpr <$> op

catchAndWarn :: Solver () -> Solver ()
catchAndWarn m = catchError m $ \e -> do  
  si <- use currentStmtIndex
  warn $ StmtError si e

warn :: SolverError -> Solver ()
warn e = errors %= (e :)

solveStmt :: Statement (Ch.InfoExpression (Ch.SymInfo, Maybe DeepSymType)) -> Solver ()
solveStmt = \case
  Pil.Def x -> do
    pv <- lookupVarSym $ x ^. Pil.var
    expr <- solveExpr $ x ^. Pil.value
    catchAndWarn $ guardSameKind pv expr
    constrain $ pv `svEqual` expr
  Pil.Constraint x -> solveExpr (x ^. Pil.condition) >>= constrain
  Pil.Store x -> do
    let exprAddr = dstToExpr $ x ^. Pil.addr
    sValue <- solveExpr $ x ^. Pil.value
    modify (\s -> s { _mem = HashMap.insert exprAddr sValue $ s ^. mem } )
    return ()
  _ -> return ()


-- | Creates SVal that represents expression.
--   This type of InfoExpression is in a TypeReport
solveExpr :: DSTExpression -> Solver SVal
-- solveExpr (Ch.InfoExpression ((Ch.SymInfo _ xsym), Nothing) _) = \
--   solverError $ "No type for sym " <> show xsym
solveExpr (Ch.InfoExpression ((Ch.SymInfo sz xsym), mdst) op) = catchFallbackAndWarn $ case op of
  Pil.ADC x -> integralBinOpWithCarry x $ \a b c -> a `svPlus` b `svPlus` c

  Pil.ADD x -> integralBinOpFirstArgIsReturn x svPlus

  Pil.ADD_OVERFLOW x ->
    integralBinOpReturnsBool x $ \a b -> unSBV $ uncurry (.||) $ bvAddO a b

  Pil.AND x -> integralBinOpFirstArgIsReturn x svAnd
  Pil.ASR x -> integralBinOpUnrelatedArgs x sSignedShiftArithRight
  Pil.BOOL_TO_INT x -> do
    b <- solveExpr $ x ^. Pil.src
    guardBool b
    k <- getRetKind
    guardIntegral k
    return $ svIte b (svInteger k 1) (svInteger k 0)

  -- TODO: stub standard libs here
--   Pil.CALL _ -> return [ (r, CSType $ TBitVector sz') ]

  Pil.CEIL x -> floatUnOp x $ SBV.fpRoundToIntegral SBV.sRoundTowardPositive
  Pil.CMP_E x -> binOpEqArgsReturnsBool x svEqual
  Pil.CMP_NE x -> binOpEqArgsReturnsBool x svNotEqual
  Pil.CMP_SGE x -> binOpEqArgsReturnsBool x svGreaterEq
  Pil.CMP_SGT x -> binOpEqArgsReturnsBool x svGreaterThan
  Pil.CMP_SLE x -> binOpEqArgsReturnsBool x svLessEq
  Pil.CMP_SLT x -> binOpEqArgsReturnsBool x svLessThan

  -- the signed and unsigned versions use the same smt func
  -- the type checker should guarantee that the args are correctly signed or unsigned
  -- but maybe TODO should be to convert signed SVal to unsigned SVal if necessary
  Pil.CMP_UGE x -> binOpEqArgsReturnsBool x svGreaterEq
  Pil.CMP_UGT x -> binOpEqArgsReturnsBool x svGreaterThan
  Pil.CMP_ULE x -> binOpEqArgsReturnsBool x svLessEq
  Pil.CMP_ULT x -> binOpEqArgsReturnsBool x svLessThan

  Pil.CONST x -> do
    k <- getRetKind
    guardIntegral k
    return . svInteger k . fromIntegral $ x ^. Pil.constant
  Pil.CONST_PTR x ->
    return . svInteger (KBounded False $ fromIntegral sz)
    . fromIntegral $ x ^. Pil.constant

  Pil.ConstStr x -> return . unSBV $ SBV.literal (cs $ x ^. Pil.value :: String)

  -- TODO: do we need to do anything special for the DP versions?
  Pil.DIVS x -> integralBinOpFirstArgIsReturn x svDivide
  Pil.DIVS_DP x -> integralBinOpDP x svDivide 
  Pil.DIVU x -> integralBinOpFirstArgIsReturn x svDivide
  Pil.DIVU_DP x -> integralBinOpDP x svDivide

  Pil.FABS x -> floatUnOp x SBV.fpAbs
  Pil.FADD x -> floatBinOp x $ SBV.fpAdd SBV.sRoundNearestTiesToAway
  Pil.FDIV x -> floatBinOp x $ SBV.fpDiv SBV.sRoundNearestTiesToAway
  Pil.FCMP_E x -> floatBinOpReturnsBool x (.==)
  Pil.FCMP_GE x -> floatBinOpReturnsBool x (.>=)
  Pil.FCMP_GT x -> floatBinOpReturnsBool x (.>)
  Pil.FCMP_LE x -> floatBinOpReturnsBool x (.<=)
  Pil.FCMP_LT x -> floatBinOpReturnsBool x (.<)
  Pil.FCMP_O x -> floatBinOpReturnsBool x $ \a b -> SBV.fpIsNaN a .~| SBV.fpIsNaN b
  Pil.FCMP_NE x -> floatBinOpReturnsBool x (./=)
  Pil.FCMP_UO x -> floatBinOpReturnsBool x $ \a b -> SBV.fpIsNaN a .|| SBV.fpIsNaN b

  -- TODO: a FIELD_ADDR should only be used inside a LOAD or Store, and hence
  -- should never be "solved". But maybe field addrs could be added to?
--   Pil.FIELD_ADDR x -> do

  Pil.FLOAT_CONST x -> return . svDouble $ x ^. Pil.constant

  Pil.FLOAT_CONV x -> do
    y <- solveExpr $ x ^. Pil.src
    case kindOf y of
      (KBounded False 32) -> return
        . unSBV
        . SBV.toSDouble SBV.sRoundNearestTiesToAway
        . SBV.sWord32AsSFloat
        . SBV $ y
      (KBounded False 64) -> return
        . unSBV
        . SBV.sWord64AsSDouble
        . SBV $ y

      k -> throwError . ErrorMessage
           $ "FLOAT_CONV expecting Unsigned integral of 32 or 64 bit width, got"
           <> show k

  Pil.FLOAT_TO_INT x -> do
    k <- getRetKind
    y <- solveExpr $ x ^. Pil.src
    guardFloat y
    case k of
      (KBounded False 64) -> unSBV <$> (f y :: Solver SBV.SWord64)
      (KBounded False 32) -> unSBV <$> (f y :: Solver SBV.SWord32)
      (KBounded False 16) -> unSBV <$> (f y :: Solver SBV.SWord16)
      (KBounded False 8) -> unSBV <$> (f y :: Solver SBV.SWord8)

      (KBounded True 64) -> unSBV <$> (f y :: Solver SBV.SInt64)
      (KBounded True 32) -> unSBV <$> (f y :: Solver SBV.SInt32)
      (KBounded True 16) -> unSBV <$> (f y :: Solver SBV.SInt16)
      (KBounded True 8) -> unSBV <$> (f y :: Solver SBV.SInt8)
      _ -> throwError . ErrorMessage
           $ "FLOAT_TO_INT: unsupported return type: " <> show k
      where
        f :: forall a. (SBV.IEEEFloatConvertible a) => SVal -> Solver (SBV a)
        f = return . SBV.fromSDouble SBV.sRoundNearestTiesToAway . SBV

  Pil.FLOOR x -> floatUnOp x $ SBV.fpRoundToIntegral SBV.sRoundTowardNegative
  Pil.FMUL x -> floatBinOp x $ SBV.fpMul SBV.sRoundNearestTiesToAway
  Pil.FNEG x -> floatUnOp x SBV.fpNeg
  Pil.FSQRT x -> floatUnOp x $ SBV.fpSqrt SBV.sRoundNearestTiesToAway
  Pil.FTRUNC x -> floatUnOp x $ SBV.fpRoundToIntegral SBV.sRoundTowardZero
  Pil.FSUB x -> floatBinOp x $ SBV.fpSub SBV.sRoundNearestTiesToAway
  Pil.IMPORT x -> return
    . svInteger (KBounded False $ fromIntegral sz)
    . fromIntegral
    $ x ^. Pil.constant

  Pil.INT_TO_FLOAT x -> do
    y <- solveExpr $ x ^. Pil.src
    let f :: forall a. SBV.IEEEFloatConvertible a => SBV a -> Solver SVal
        f = return . unSBV . SBV.toSDouble SBV.sRoundNearestTiesToAway
    case kindOf y of
      (KBounded True 8) -> f (SBV y :: SBV.SInt8)
      (KBounded True 16) -> f (SBV y :: SBV.SInt16)
      (KBounded True 32) -> f (SBV y :: SBV.SInt32)
      (KBounded True 64) -> f (SBV y :: SBV.SInt64)

      (KBounded False 8) -> f (SBV y :: SBV.SWord8)
      (KBounded False 16) -> f (SBV y :: SBV.SWord16)
      (KBounded False 32) -> f (SBV y :: SBV.SWord32)
      (KBounded False 64) -> f (SBV y :: SBV.SWord64)
      k -> throwError . ErrorMessage
           $ "INT_TO_FLOAT: unsupported return type: " <> show k

  Pil.LOAD x -> do
    m <- use mem
    let key = dstToExpr $ x ^. Pil.src
    maybe (createFreeVar key) return $ HashMap.lookup key m
    where
      createFreeVar k = do
        freeVar <- fallbackAsFreeVar
        mem %= HashMap.insert k freeVar
        return freeVar

--   -- should _x have any influence on the type of r?
  Pil.LOW_PART x -> integralUnOp x (lowPart sz)
  Pil.LSL x -> integralBinOpUnrelatedArgs x svShiftLeft
  Pil.LSR x -> integralBinOpUnrelatedArgs x svShiftRight
  Pil.MODS x -> integralBinOpFirstArgIsReturn x svRem
  Pil.MODS_DP x -> integralBinOpDP x svRem
  Pil.MODU x -> integralBinOpFirstArgIsReturn x svRem
  Pil.MODU_DP x -> integralBinOpDP x svRem
  Pil.MUL x -> integralBinOpFirstArgIsReturn x svTimes
  Pil.MULS_DP x -> integralBinOpDP x svTimes
  Pil.MULU_DP x -> integralBinOpDP x svTimes
  Pil.NEG x -> integralUnOp x svUNeg

  Pil.NOT x -> do
    y <- solveExpr $ x ^. Pil.src
    let k = kindOf y
    case k of
      KBool -> return $ unSBV . SBV.sNot . toSBool' $ y
      (KBounded _ _) -> return $ svNot y
      _ -> throwError . ErrorMessage $ "NOT expecting Bool or Integral, got " <> show k

  Pil.OR x -> integralBinOpFirstArgIsReturn x svOr
  Pil.RLC x -> rotateBinOpWithCarry x $ rotateWithCarry svRotateLeft
  Pil.ROL x -> integralBinOpUnrelatedArgs x svRotateLeft
  Pil.ROR x -> integralBinOpUnrelatedArgs x svRotateRight
--   Pil.ROUND_TO_INT x -> floatToInt x
  Pil.RRC x -> rotateBinOpWithCarry x $ rotateWithCarry svRotateRight
  Pil.SBB x -> integralBinOpWithCarry x $ \a b c -> (a `svMinus` b) `svMinus` c
-- --   -- STORAGE _ -> unknown
-- --   StrCmp _ -> intRet
-- --   StrNCmp _ -> intRet
-- --   MemCmp _ -> intRet
--   -- should this somehow be linked to the type of the stack var?
--   -- its type could change every Store.
--   Pil.STACK_LOCAL_ADDR _ -> retPointer

  Pil.SUB x -> integralBinOpFirstArgIsReturn x pilSub

  Pil.SX x -> bitVectorUnOp x (signExtend sz)

  -- TODO: should this return Bool?
  Pil.TEST_BIT x -> bitVectorBinOp x $ \a b -> case kindOf a of
    KBounded _ w -> (a `svAnd` (svExp (constWord (Bits w') 2) b)) `svGreaterThan` constWord (Bits w') 0
      where
        w' = fromIntegral w
    -- TODO: Throw error if not KBounded
    _ -> svFalse

  Pil.UNIMPL _ -> return svTrue

  Pil.UPDATE_VAR x -> do
    dest <- lookupVarSym $ x ^. Pil.dest
    src <- solveExpr $ x ^. Pil.src
    guardIntegral dest
    guardIntegral src
    --TODO: convert dest and src to unsigned and convert them back if needed
    return $ updateBitVec (toBitOffset $ x ^. Pil.offset) src dest
    
  --   -- How should src and dest be related?
  --   -- Can't express that `offset + width(src) == width(dest)`
  --   --  without `+` and `==` as type level operators.
  --   return [ (r, CSVar v) ]

  Pil.VAR x -> lookupVarSym $ x ^. Pil.src

  -- TODO: add VAR_FIELD test
  -- also, maybe convert the offset to bits?
  Pil.VAR_FIELD x -> do
    v <- lookupVarSym $ x ^. Pil.src
    return $ svExtract (off + w - 1) off v 
    where
      off = fromIntegral . toBitOffset $ x ^. Pil.offset
      w = fromIntegral sz

  -- this should really be called VAR_JOIN
  Pil.VAR_SPLIT x -> do    
    low <- lookupVarSym $ x ^. Pil.low
    high <- lookupVarSym $ x ^. Pil.high
    guardIntegral low
    guardIntegral high
    return $ svJoin high low

  Pil.XOR x -> bitVectorBinOp x svXOr
  Pil.ZX x -> bitVectorUnOp x (zeroExtend sz)
-- --   Extract _ -> bitvecRet
        -- expr offset sz --> expr 0 sz -> takes low sz of expr
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

    getRetKind = getDst >>= deepSymTypeToKind

    catchFallbackAndWarn :: Solver SVal -> Solver SVal
    catchFallbackAndWarn m = catchError m $ \e -> do  
      si <- use currentStmtIndex
      warn $ StmtError si e
      fallbackAsFreeVar
      
    binOpEqArgsReturnsBool :: ( Pil.HasLeft x DSTExpression
                              , Pil.HasRight x DSTExpression)
                              => x -> (SVal -> SVal -> SVal) -> Solver SVal
    binOpEqArgsReturnsBool x f = do
      lx <- solveExpr (x ^. Pil.left)
      rx <- solveExpr (x ^. Pil.right)
      guardSameKind lx rx
      return $ f lx rx

    -- | doesn't match second arg to first
    integralBinOpUnrelatedArgs :: ( Pil.HasLeft x DSTExpression
                                , Pil.HasRight x DSTExpression)
                               => x -> (SVal -> SVal -> SVal) -> Solver SVal
    integralBinOpUnrelatedArgs x f = do
      lx <- solveExpr (x ^. Pil.left)
      rx <- solveExpr (x ^. Pil.right)
      guardIntegral lx
      guardIntegral rx
      return $ f lx rx

    -- | assumes first arg width >= second arg width
    -- matches second args sign and width to equal first
    integralBinOpFirstArgIsReturn :: ( Pil.HasLeft x DSTExpression
                                     , Pil.HasRight x DSTExpression)
                                  => x -> (SVal -> SVal -> SVal) -> Solver SVal
    integralBinOpFirstArgIsReturn x f = do
      lx <- solveExpr (x ^. Pil.left)
      rx <- solveExpr (x ^. Pil.right)
      guardIntegralFirstWidthNotSmaller lx rx
      let rx' = matchSign lx (matchBoundedWidth lx rx)
      return $ f lx rx'

    -- | left and right are integral, right is resized/resigned to match first
    integralBinOpReturnsBool :: ( Pil.HasLeft x DSTExpression
                                , Pil.HasRight x DSTExpression)
                             => x -> (SVal -> SVal -> SVal) -> Solver SVal
    integralBinOpReturnsBool x f = do
      lx <- solveExpr (x ^. Pil.left)
      rx <- solveExpr (x ^. Pil.right)
      guardIntegralFirstWidthNotSmaller lx rx
      let rx' = matchSign lx (matchBoundedWidth lx rx)
      return $ f lx rx'


    floatBinOp :: ( Pil.HasLeft x DSTExpression
                  , Pil.HasRight x DSTExpression )
               => x
               -> (SBV.SDouble -> SBV.SDouble -> SBV.SDouble) -> Solver SVal
    floatBinOp x f = do
      lx <- toSFloat =<< solveExpr (x ^. Pil.left)
      rx <- toSFloat =<< solveExpr (x ^. Pil.right)
      return . unSBV $ f lx rx

    floatBinOpReturnsBool :: ( Pil.HasLeft x DSTExpression
                             , Pil.HasRight x DSTExpression )
                          => x
                          -> (SBV.SDouble -> SBV.SDouble -> SBool) -> Solver SVal
    floatBinOpReturnsBool x f = do
      lx <- toSFloat =<< solveExpr (x ^. Pil.left)
      rx <- toSFloat =<< solveExpr (x ^. Pil.right)
      return . unSBV $ f lx rx


    bitVectorUnOp :: Pil.HasSrc x DSTExpression
               => x
               -> (SVal -> SVal) -> Solver SVal
    bitVectorUnOp = integralUnOp

    integralUnOp :: Pil.HasSrc x DSTExpression
               => x
               -> (SVal -> SVal) -> Solver SVal
    integralUnOp x f = do
      lx <- solveExpr (x ^. Pil.src)
      guardIntegral lx
      return $ f lx

    floatUnOp :: Pil.HasSrc x DSTExpression
              => x
              -> (SBV.SDouble -> SBV.SDouble) -> Solver SVal
    floatUnOp x f = do
      lx <- solveExpr (x ^. Pil.src)
      unSBV . f <$> toSFloat lx

    -- | first arg is double width of second and return arg
    -- so we have to increase width of second, then shrink result by half
    integralBinOpDP :: ( Pil.HasLeft x DSTExpression
                       , Pil.HasRight x DSTExpression )
                    => Maybe Bool
                    -> x
                    -> (SVal -> SVal -> SVal) -> Solver SVal
    integralBinOpDP mSignedness x f = do
      

    binOpSameType :: ( Pil.HasLeft x DSTExpression
                     , Pil.HasRight x DSTExpression )
                  => x -> (SVal -> SVal -> SVal) -> Solver SVal
    binOpSameType x f = do
      lx <- solveExpr (x ^. Pil.left)
      rx <- solveExpr (x ^. Pil.right)
      guardSameKind lx rx
      return $ f lx rx


    bitVectorBinOp :: ( Pil.HasLeft x DSTExpression
                      , Pil.HasRight x DSTExpression )
                   => x
                   -> (SVal -> SVal -> SVal) -> Solver SVal
    bitVectorBinOp x f = do
      lx <- solveExpr (x ^. Pil.left)
      rx <- solveExpr (x ^. Pil.right)
      guardIntegral lx
      guardIntegral rx      
      return $ f lx rx

    integralBinOpWithCarry :: ( HasLeft x DSTExpression
             , HasRight x DSTExpression
             , HasCarry x DSTExpression)
          => x
          -> (SVal -> SVal -> SVal -> SVal) -> Solver SVal
    integralBinOpWithCarry x f = do
      a <- solveExpr (x ^. Pil.left)
      b <- solveExpr (x ^. Pil.right)
      c <- solveExpr (x ^. Pil.carry)
      guardIntegralFirstWidthNotSmaller a b
      cAsInt <- boolToInt (kindOf a) c
      
      let b' = matchSign a (matchBoundedWidth a b)
      return $ f a b' cAsInt


    rotateBinOpWithCarry :: ( HasLeft x DSTExpression
             , HasRight x DSTExpression
             , HasCarry x DSTExpression)
          => x
          -> (SVal -> SVal -> SVal -> SVal) -> Solver SVal
    rotateBinOpWithCarry x f = do
      a <- solveExpr (x ^. Pil.left)
      b <- solveExpr (x ^. Pil.right)
      c <- solveExpr (x ^. Pil.carry)
      return $ f a b c

solveTypedStmtsWith :: SMTConfig
                    -> HashMap PilVar DeepSymType
                    -> [(Int, Statement (Ch.InfoExpression (Ch.SymInfo, Maybe DeepSymType)))]
                    -> IO (Either SolverError SolverReport)
solveTypedStmtsWith solverCfg vartypes stmts = do
  er <- runSolverWith solverCfg run (emptyState, SolverCtx vartypes)
  return $ toSolverReport <$> er
  where
    toSolverReport :: (SolverResult, SolverState) -> SolverReport
    toSolverReport (r, s) = SolverReport r (s ^. errors)
    run = do
      declarePilVars
      mapM_ f stmts
      querySolverResult
    f (ix, stmt) = do
      currentStmtIndex .= ix
      solveStmt stmt

-- | runs type checker first, then solver
solveStmtsWith :: SMTConfig
               -> [Statement Expression]
               -> IO (Either
                      (Either
                       Ch.ConstraintGenError
                       (SolverError, Ch.TypeReport))
                      (SolverReport, Ch.TypeReport))
solveStmtsWith solverCfg stmts = do
  -- should essential analysis steps be included here?
  -- let stmts' = Analysis.substFields stmts
  let er = Ch.checkStmts stmts
  case er of
    Left e -> return $ Left (Left e)
    Right tr -> solveTypedStmtsWith solverCfg (tr ^. Ch.varSymTypeMap) (tr ^. Ch.symTypeStmts) >>= \case
      Left e -> return $ Left (Right (e, tr))
      Right sr -> return $ Right (sr, tr)

-- | convenience function for checking statements.
-- any errors in Type Checker or Solver result in Unk
-- warnings are ignored
solveStmtsWith_ :: SMTConfig
                -> [Statement Expression]
                -> IO (SolverResult)
solveStmtsWith_ solverCfg stmts = solveStmtsWith solverCfg stmts >>= \case
  Left _ -> return Unk
  Right (r, _) -> return $ r ^. result

solvePathWith :: SMTConfig -> Function -> AlgaPath
              -> IO (Either
                     (Either
                      Ch.ConstraintGenError
                      (SolverError, Ch.TypeReport))
                     (SolverReport, Ch.TypeReport))
solvePathWith solverCfg startFunc p = do
  stmts <- Path.convertPath startFunc p
  let stmts' = Analysis.substFields $ stmts
  solveStmtsWith solverCfg stmts'


solvePathWith_ :: SMTConfig -> Function -> AlgaPath -> IO (SolverResult)
solvePathWith_ solverCfg startFunc p = do
  stmts <- Path.convertPath startFunc p
  let stmts' = Analysis.substFields $ stmts
  solveStmtsWith_ solverCfg stmts'
