module Blaze.Cfg.Interprocedural (
  module Blaze.Cfg.Interprocedural,
  module Exports,
) where

import Blaze.Prelude hiding (Symbol, sym)

import Blaze.Cfg
import Blaze.Function (FuncParamInfo (FuncParamInfo, FuncVarArgInfo), Function)
import qualified Blaze.Graph as G
import Blaze.Types.Cfg.Interprocedural as Exports
import Blaze.Types.Import (ImportResult (ImportResult))
import Blaze.Types.Pil (
  CallDest (CallFunc),
  CallStatement,
  Ctx,
  DefOp (DefOp),
  DefPhiOp (DefPhiOp),
  Expression,
  PilVar (PilVar),
  Statement (Def, DefPhi),
  Stmt,
  Symbol,
  mkCallStatement, CtxIndex
 )
import qualified Data.List.NonEmpty as NEList
import qualified Data.Set as Set
import Control.Lens.Setter (set)
import Blaze.Graph (LEdge)

getCallTarget :: CallStatement -> Maybe Function
getCallTarget callStmt = do
  let callDest = callStmt ^. #callOp . #dest
  case callDest of
    CallFunc fun -> Just fun
    _ -> Nothing

getCallStmt :: PilCallNode -> Maybe CallStatement
getCallStmt node = do
  stmt <- headMay (node ^. #nodeData)
  mkCallStatement stmt

mkParamVar :: Ctx -> FuncParamInfo -> PilVar
mkParamVar ctx funcParam =
  PilVar sym (Just ctx)
 where
  sym :: Symbol
  sym = case funcParam of
    FuncParamInfo paramInfo -> coerce $ paramInfo ^. #name
    FuncVarArgInfo paramInfo -> coerce $ paramInfo ^. #name

-- | Create a node that indicates a context switch between two function contexts.
mkEnterFuncNode :: Ctx -> Ctx -> CallStatement -> EnterFuncNode [Stmt]
mkEnterFuncNode outerCtx calleeCtx callStmt =
  EnterFuncNode outerCtx calleeCtx stmts
 where
  paramVars :: [PilVar]
  paramVars = mkParamVar calleeCtx <$> calleeCtx ^. #func . #params
  stmts :: [Stmt]
  stmts = Def . uncurry DefOp <$> zip paramVars (callStmt ^. #args)

{- |Generate a defintion for the result variable in the outer (caller) context
where the a phi function containing variables that reference all the possible
return expressions from potentially multiple return sites in the callee are listed.
Since a return statement may return an expression, we first ensure a variable referencing
the expressions is available by generating one for each expression. This may end up
introducing spurious variable copies which can be reduced with copy propagation.
-}
mkLeaveFuncNode :: Ctx -> Ctx -> CallStatement -> [Expression] -> LeaveFuncNode [Stmt]
mkLeaveFuncNode outerCtx calleeCtx callStmt retExprs =
  LeaveFuncNode calleeCtx outerCtx stmts
 where
  resultVar :: Maybe PilVar
  resultVar = callStmt ^. #resultVar
  retVars :: [(PilVar, Expression)]
  retVars = generateVars calleeCtx "retVar_" 0 retExprs
  retDefs :: [Stmt]
  retDefs = Def . uncurry DefOp <$> retVars
  resultDef :: Maybe Stmt
  resultDef = DefPhi <$> (DefPhiOp <$> resultVar <*> Just (fst <$> retVars))
  stmts :: [Stmt]
  stmts = case resultDef of
    Just stmt -> retDefs ++ [stmt]
    Nothing -> []

generateVars :: Ctx -> Text -> Int -> [Expression] -> [(PilVar, Expression)]
generateVars ctx baseName id (expr : rest) =
  (PilVar (baseName <> show id) (Just ctx), expr) : generateVars ctx baseName (id + 1) rest
generateVars _ _ _ [] = []

getNextCtxIndex :: Builder a CtxIndex
getNextCtxIndex = do
  ctxIndex <- use #nextId
  #nextId %= (+ 1)
  return ctxIndex

{- | Expand a call by substituting a call node with the CFG corresponding to the
 call destination.
-}
expandCall ::
  Ctx ->
  Ctx ->
  InterCfg ->
  PilCallNode ->
  Builder a (Maybe InterCfg)
expandCall callerCtx calleeCtx icfg callNode = do
  getCfg_ <- use #getCfg
  -- ctxIndex <- getNextCtxIndex
  case getCallStmt callNode of
    Just callStmt ->
      -- TODO: CallNode should provide the call statement from a record field
      case getCallTarget callStmt of
        Just targetFunc -> do
          -- result <- liftIO $ getCfg_ ctxIndex targetFunc
          result <- liftIO $ getCfg_ (calleeCtx ^. #ctxIndex) targetFunc
          case result of
            Just (ImportResult targetCfg _) -> do
              let (targetCfg', leaveFunc) = expandCall_ callerCtx calleeCtx callStmt targetCfg
              return $ Just $ substNode icfg (Call callNode) (InterCfg targetCfg') leaveFunc
            Nothing -> return Nothing
        Nothing -> return Nothing
    Nothing -> return Nothing

expandCall_ ::
  Ctx ->
  Ctx ->
  CallStatement ->
  PilCfg ->
  (PilCfg, PilNode)
expandCall_ callerCtx calleeCtx callStmt targetCfg = 
  (targetCfg', leaveFunc)
  -- Connect the enter and leave function nodes to the targetCfg
 where
  enterFunc = EnterFunc $ mkEnterFuncNode callerCtx calleeCtx callStmt
  leaveFunc = LeaveFunc $ mkLeaveFuncNode callerCtx calleeCtx callStmt (getRetExprs targetCfg)
  prevRoot = targetCfg ^. #root
  retNodes = getRetNodes targetCfg
  linkRetNodes :: PilCfg -> ReturnNode [Stmt] -> PilCfg
  linkRetNodes cfg retNode =
    G.addEdge
      (UnconditionalBranch, (BasicBlock $ retNode ^. #basicBlock, leaveFunc))
      cfg
  targetCfg' :: PilCfg
  targetCfg' = 
    foldl'
      linkRetNodes
      ( G.addEdge (UnconditionalBranch, (enterFunc, prevRoot)) $
          targetCfg & #root .~ enterFunc
      )
      retNodes

getRetNodes :: PilCfg -> [ReturnNode [Stmt]]
getRetNodes cfg = 
  mapMaybe (\tn -> tn ^? #_TermRet) $ NEList.toList (getTerminalBlocks cfg)

-- | Substitute a node with another interprocedural CFG.
substNode :: InterCfg -> PilNode -> InterCfg -> PilNode -> InterCfg
substNode
  (InterCfg (Cfg outerGraph outerRoot))
  node
  (InterCfg (Cfg innerGraph innerRoot))
  exitNode =
    -- Check if the node we are substituting is the outer CFG's root
    if outerRoot /= node
      then InterCfg (Cfg graph_ outerRoot)
      else InterCfg (Cfg graph_ innerRoot)
   where
    -- TODO: Improve Graph API for fetching edges
    predEdges :: [LEdge BranchType PilNode]
    predEdges = filter (\(_, (_, dest)) -> dest == node) $ G.edges outerGraph
    succEdges :: [LEdge BranchType PilNode]
    succEdges = filter (\(_, (source, _)) -> source == node) $ G.edges outerGraph
    newPredEdges :: [LEdge BranchType PilNode]
    newPredEdges = set (_2 . _2) innerRoot <$> predEdges
    newSuccEdges :: [LEdge BranchType PilNode]
    newSuccEdges = set (_2 . _1) exitNode <$> succEdges
    graph_ :: ControlFlowGraph [Stmt]
    graph_ = 
      G.removeNode node
      . G.addNodes (Set.toList $ G.nodes innerGraph)
      . G.addEdges (G.edges innerGraph) 
      . G.addEdges newPredEdges
      . G.addEdges newSuccEdges $ outerGraph