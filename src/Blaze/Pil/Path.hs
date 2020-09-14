module Blaze.Pil.Path where

import Binja.Function (Function)
import qualified Binja.Function as BNFunc
import qualified Binja.MLIL as MLIL
import qualified Binja.Variable as BNVar
import qualified Blaze.Pil as Pil
import Blaze.Prelude hiding (sym)
import Blaze.Types.Function (CallSite)
import qualified Blaze.Types.Function as Func
import Blaze.Types.Path
  ( AbstractCallNode,
    CallNode,
    ConditionNode,
    Node
      ( AbstractCall,
        Call,
        Condition,
        Ret,
        SubBlock
      ),
    RetNode,
    SubBlockNode,
  )
import qualified Blaze.Types.Path as Path
import Blaze.Types.Path.AlgaPath (AlgaPath)
import Blaze.Types.Pil
  ( Converter,
    ConverterState (ConverterState),
    Ctx (Ctx),
    CtxIndex,
    Stmt,
    runConverter,
  )
import qualified Blaze.Types.Pil as Pil
import qualified Data.HashSet as HS
import qualified Data.List.NonEmpty as NE

-- convert path to [Pil]

-- updates ctx if Function is new
-- TODO: WHy use this?
-- I don't think the ctx can change without a Call node
maybeUpdateCtx :: Function -> Converter ()
maybeUpdateCtx fn = do
  cctx <- get
  when (fn /= cctx ^. Pil.ctx . Pil.func) . enterNewCtx $ fn

enterNewCtx :: Function -> Converter ()
enterNewCtx fn = do
  Pil.ctxMaxIdx %= incIndex
  i <- use Pil.ctxMaxIdx
  outerCtx <- use Pil.ctx
  
  let innerCtx = newCtx i outerCtx
  Pil.ctx .= innerCtx
  pushCtx innerCtx

  where
    newCtx :: CtxIndex -> Ctx -> Ctx
    newCtx i ctx = ctx & Pil.func .~ fn
                       & Pil.ctxIndex .~ i
    incIndex :: CtxIndex -> CtxIndex
    incIndex = (+ 1)
    pushCtx :: Ctx -> Converter ()
    pushCtx ctx = Pil.ctxStack %= NE.cons ctx

retCtx :: Converter ()
retCtx = do
  _innerCtx <- popCtx
  outerCtx <- peekCtx
  Pil.ctx .= outerCtx
  where
    popCtx :: Converter Ctx
    popCtx = do
      stack <- use Pil.ctxStack
      let (_innerCtx, mStack) = NE.uncons stack
      case mStack of 
        Just stack' -> do
          Pil.ctxStack .= stack'
          return _innerCtx
        Nothing -> error "The converter stack should never be empty."
    peekCtx :: Converter Ctx
    peekCtx = do
      stack <- use Pil.ctxStack
      return $ NE.head stack

peekPrevCtx :: Converter (Maybe Ctx)
peekPrevCtx = do
  stack <- use Pil.ctxStack
  return $ headMay . NE.tail $ stack

convertSubBlockNode :: SubBlockNode -> Converter [Stmt]
convertSubBlockNode sb = do
  maybeUpdateCtx $ sb ^. Path.func
  instrs <- liftIO $ do
    mlilFunc <- BNFunc.getMLILSSAFunction $ sb ^. Path.func
    mapM (MLIL.instruction mlilFunc) [(sb ^. Path.start) .. (sb ^. Path.end - 1)]
  Pil.convertInstrs instrs

convertConditionNode :: ConditionNode -> Converter [Stmt]
convertConditionNode n = do
  expr <- Pil.convertExpr $ n ^. Path.condition
  return . (:[]) . Pil.Constraint . Pil.ConstraintOp $
    if n ^. Path.trueOrFalseBranch
    then expr
    else Pil.Expression (expr ^. Pil.size) (Pil.NOT . Pil.NotOp $ expr)

convertAbstractCallNode :: AbstractCallNode -> Converter [Stmt]
convertAbstractCallNode n = do
  ctx <- use Pil.ctx
  Pil.convertCallInstruction ctx (n ^. Path.callSite . Func.callInstr)

-- TODO: Check this earlier in the conversion process? 
getCallDestFunc :: CallSite -> Function
getCallDestFunc x = case x ^. Func.callDest of
  (Func.DestFunc f) -> f
  _ -> error "Only calls to known functions may be expanded."

defSymbol :: Pil.Symbol -> Pil.Expression -> Converter Stmt
defSymbol sym expr = do
  ctx <- use Pil.ctx
  -- TODO: Sort out use of mapsTo when defining the PilVar
  let pilVar = Pil.PilVar sym (Just ctx) HS.empty
  return $ Pil.Def (Pil.DefOp pilVar expr)

defPilVar :: Pil.PilVar -> Pil.Expression -> Stmt
defPilVar pilVar expr = Pil.Def (Pil.DefOp pilVar expr)

createParamSymbol :: Int -> BNVar.Variable -> Pil.Symbol
createParamSymbol version var =
  coerce name <> "#" <> show version
    where
      name :: Text
      name = var ^. BNVar.name

convertCallNode :: CallNode -> Converter [Stmt]
convertCallNode n = do
  let destFunc = getCallDestFunc $ n ^. Path.callSite
      callInstr = n ^. (Path.callSite . Func.callInstr)
  -- The argument expressions should be converted in the caller's context.
  -- Convert before entering the new callee's context.
  argExprs <- traverse Pil.convertExpr (callInstr ^. Func.params)
  enterNewCtx destFunc
  ctx <- use Pil.ctx
  params <- liftIO $ BNVar.getFunctionParameterVariables destFunc
  let paramSyms = createParamSymbol 0 <$> params
  defs <- zipWithM defSymbol paramSyms argExprs
  return $ (Pil.EnterContext . Pil.EnterContextOp $ ctx) : defs

getRetVals_ :: SubBlockNode -> Converter [Pil.Expression]
getRetVals_ node = do
  mlilFunc <- liftIO $ BNFunc.getMLILSSAFunction $ node ^. Path.func
  lastInstr <- liftIO $ MLIL.instruction mlilFunc $ node ^. Path.end - 1
  case lastInstr ^? (MLIL.op . MLIL._RET) of
    (Just retOp) ->
      traverse Pil.convertExpr (retOp ^. MLIL.src)
    Nothing ->
      error "Missing required return instruction."

getRetVals :: RetNode -> Converter [Pil.Expression]
getRetVals retNode = do
  path <- use Pil.path
  case Path.pred (Ret retNode) path >>= (^? Path._SubBlock) of
    (Just prevNode) ->
      getRetVals_ prevNode
    Nothing ->
      error "RetNode not preceded by a SubBlockNode."

convertRetNode :: RetNode -> Converter [Stmt]
convertRetNode node = do
  leavingCtx <- use Pil.ctx
  retVals <- getRetVals node
  retCtx
  returningCtx <- use Pil.ctx
  resultVars <- traverse Pil.convertToPilVarAndLog (node ^. Path.callSite . Func.callInstr . Func.outputDest)
  let defs = zipWith defPilVar resultVars retVals
  return $ Pil.ExitContext (Pil.ExitContextOp leavingCtx returningCtx) : defs

convertNode :: Node -> Converter [Stmt]
convertNode (SubBlock x) = convertSubBlockNode x
convertNode (Condition x) = convertConditionNode x
convertNode (AbstractCall x) = convertAbstractCallNode x
convertNode (Call x) = convertCallNode x
convertNode (Ret x) = convertRetNode x
convertNode _ = return [] -- TODO

convertNodes :: [Node] -> Converter [Stmt]
convertNodes = fmap concat . traverse convertNode

createStartCtx :: Function -> Ctx
createStartCtx func = Ctx func 0

createStartConverterState :: AlgaPath -> Function -> ConverterState
createStartConverterState path func = 
  ConverterState path (startCtx ^. Pil.ctxIndex) (startCtx :| []) startCtx [] HS.empty Pil.knownFuncDefs
    where 
      startCtx :: Ctx
      startCtx = createStartCtx func

convertPath :: Function -> AlgaPath -> IO [Stmt]
convertPath startFunc path =
  fmap (concat . fst) . flip runConverter (createStartConverterState path startFunc) . traverse convertNode . Path.toList $ path
