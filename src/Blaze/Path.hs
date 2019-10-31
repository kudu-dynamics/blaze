{-# LANGUAGE TemplateHaskell #-}

module Blaze.Path
  ( module Exports
  , module Blaze.Path
  ) where

import           Blaze.Prelude

import           Binja.BasicBlock                  ( BasicBlock
                                                   , BasicBlockFunction
                                                   , BlockEdge
                                                   )
import qualified Binja.BasicBlock     as BB
import           Binja.C.Enums                     ( BNBranchType( FalseBranch
                                                                 , TrueBranch
                                                                 )
                                                   )
import           Binja.Core                        ( BNBinaryView
                                                   , InstructionIndex
                                                   )
import           Binja.Function                    ( Function
                                                   )
import qualified Binja.Function       as HFunction
import qualified Binja.MLIL           as MLIL
import           Blaze.Function                    ( createCallSite )
import qualified Blaze.Function       as Function
import           Blaze.Graph.Alga                  ( AlgaGraph )
import           Blaze.Types.Function              ( CallInstruction
                                                   , CallSite
                                                   , toCallInstruction
                                                   )
import           Blaze.Types.Graph                 ( Graph )
import qualified Blaze.Types.Graph    as G
import           Blaze.Types.Path     as Exports
import qualified Blaze.Types.Pil      as Pil

type BasicBlockGraph t = AlgaGraph () (BasicBlock t)

newtype AlgaPath = AlgaPath (PathGraph (AlgaGraph () Node))
  deriving (Graph () Node, Path)


-- constructBasicBlockGraph :: (Ord t, BasicBlockFunction t)
--                          => t -> IO (BasicBlockGraph t)
-- constructBasicBlockGraph fn = do

--   bbs <- BB.getBasicBlocks fn
--   succs <- traverse cleanSuccs bbs
--   return . G.edges $ succsToEdges succs
--   where
--     cleanSuccs :: BasicBlockFunction t => BasicBlock t -> IO (BasicBlock t, [BasicBlock t])
--     cleanSuccs bb = (bb,) . catMaybes . fmap (view BB.target)
--                     <$> BB.getOutgoingEdges bb
--     succsToEdges :: [(a, [a])] -> [(a, a)]
--     succsToEdges xs = do
--       (x, ys) <- xs
--       y <- ys
--       return (x, y)


-- constructBasicBlockGraph :: (Ord t, BasicBlockFunction t)
--                          => t -> IO (BasicBlockGraph t)
-- constructBasicBlockGraph fn = do
--   bbs <- BB.getBasicBlocks fn
--   succs' <- traverse cleanSuccs bbs
--   return . G.fromEdges . fmap ((),) $ succsToEdges succs'
--   where
--     cleanSuccs :: BasicBlockFunction t => BasicBlock t -> IO (BasicBlock t, [BasicBlock t])
--     cleanSuccs bb = (bb,) . catMaybes . fmap (view BB.target)
--                     <$> BB.getOutgoingEdges bb
--     succsToEdges :: [(a, [a])] -> [(a, a)]
--     succsToEdges xs = do
--       (x, ys) <- xs
--       y <- ys
--       return (x, y)


--- todo: shouldn't the edges be (Maybe Condition)? Yes, they should.
constructBasicBlockGraph :: (Graph (BlockEdge t) (BasicBlock t) g, BasicBlockFunction t)
                         => t -> IO g
constructBasicBlockGraph fn = do
  bbs <- BB.getBasicBlocks fn
  succs' <- traverse cleanSuccs bbs
  return . G.fromEdges . succsToEdges $ succs'
  where
    cleanSuccs :: BasicBlockFunction t => BasicBlock t -> IO (BasicBlock t, [(BlockEdge t, BasicBlock t)])
    cleanSuccs bb = (bb,) . catMaybes . fmap (\e -> (e,) <$>  (e ^. BB.target))
                    <$> BB.getOutgoingEdges bb
    succsToEdges :: [(a, [(e, a)])] -> [(e, (a, a))]
    succsToEdges xs = do
      (x, ys) <- xs
      (e, y) <- ys
      return (e, (x, y))


type Condition = Pil.Expression

data CallCombo = CallCombo { callNode :: CallNode
                           , abstractPathNode :: AbstractPathNode
                           , retNode :: RetNode }
               deriving (Eq, Ord, Show)

callCombo :: Function -> CallSite -> IO CallCombo
callCombo fn cs' = do
  call <- CallNode fn cs' <$> randomIO
  ret <- RetNode fn cs' <$> randomIO
  apn <- AbstractPathNode fn (Call call) (Ret ret) <$> randomIO
  return $ CallCombo call apn ret

data SpanItem a b = SpanSpan (a, a)
                  | SpanBreak b
                  deriving (Show)

-- assumes [a] is sorted without duplicates and forall a in [a], a < hi
getSpanList :: Integral a => (b -> a) -> a -> a -> [b] -> [SpanItem a b]
getSpanList _ lo hi [] = if lo == hi then [] else [SpanSpan (lo, hi)]
getSpanList f lo hi (x:xs)
  | lo == n = (SpanBreak x):getSpanList f (lo + 1) hi xs
  | otherwise = SpanSpan (lo, n) : SpanBreak x : getSpanList f (n + 1) hi xs
  where
    n = f x

convertBasicBlockToNodeList :: BNBinaryView -> BasicBlock F -> IO [Node]
convertBasicBlockToNodeList bv bb = do
  calls <- mapMaybe toCallInstruction <$> MLIL.fromBasicBlock bb
  let spans = getSpanList (view Function.index) (bb ^. BB.start) (bb ^. BB.end) calls
  concat <$> traverse f spans
  where
    fn = bb ^. BB.func . HFunction.func

    f :: SpanItem (InstructionIndex F) (CallInstruction) -> IO [Node]
    f (SpanSpan (lo, hi)) = (:[]) . SubBlock . SubBlockNode fn (bb ^. BB.start) lo hi <$> randomIO
    f (SpanBreak ci) = do
      n <- AbstractCallNode fn <$> (createCallSite bv fn ci) <*> randomIO
      return [AbstractCall n]

pairs :: [a] -> [(a, a)]
pairs xs = zip xs $ drop 1 xs

mpairs :: [a] -> [(a, Maybe a)]
mpairs [] = []
mpairs [x] = [(x, Nothing)]
mpairs (x:y:xs) = (x, Just y) : mpairs (y:xs)


getConditionNode :: BlockEdge F -> IO (Maybe ConditionNode)
getConditionNode edge = case edge ^. BB.branchType of
  TrueBranch -> f True
  FalseBranch -> f False
  _ -> return Nothing
  where
    bb = edge ^. BB.src
    fn = bb ^. BB.func . HFunction.func
    f isTrueBranch = do
      endInstr <- MLIL.instruction (bb ^. BB.func) (bb ^. BB.end - 1)
      case endInstr ^. MLIL.op of
        MLIL.IF op -> return . Just . ConditionNode fn isTrueBranch $ op ^. MLIL.condition
        _ -> return Nothing


pathFromBasicBlockList :: (Graph (BlockEdge F) (BasicBlock F) g, Path p)
                       => BNBinaryView -> g -> [BasicBlock F] -> IO p
pathFromBasicBlockList bv g = fmap (fromList . concat) . traverse f . mpairs
  where
    f :: (BasicBlock F, Maybe (BasicBlock F)) -> IO [Node]
    f (bb, Nothing) = convertBasicBlockToNodeList bv bb
    f (bb, (Just bbnext)) = do
      nodes <- convertBasicBlockToNodeList bv bb
      mcond <- case G.getEdgeLabel (bb, bbnext) g of
        Nothing -> return Nothing
        Just edge -> getConditionNode edge
      return . maybe nodes ((nodes <>) . (:[]) . Condition) $ mcond


simplePathsFromBasicBlockGraph :: (Graph (BlockEdge F) (BasicBlock F) g, Path p)
                               => BNBinaryView -> g -> IO [p]
simplePathsFromBasicBlockGraph bv g =
  traverse (pathFromBasicBlockList bv g) . G.findAllSimplePaths $ g


allSimpleFunctionPaths :: Path p => BNBinaryView -> Function -> IO [p]
allSimpleFunctionPaths bv fn = do
  mlilFn <- HFunction.getMLILSSAFunction fn
  bbg <- constructBasicBlockGraph mlilFn :: IO (AlgaGraph (BlockEdge F) (BasicBlock F))
  simplePathsFromBasicBlockGraph bv bbg

  
-- create map of bb -> [Node]
-- create map of bb -> first Node
-- create map of bb -> last Node
-- for each bb, get outgoing edges, convert them to "first Node"
-- create edges for nodes in each bb
-- create edges of last Node -> first Node for each bb (don't forget about conditionals!)

--- OOOOr, make an `expandNode` function
-- insertSubgraph :: Graph e n -> n -> Graph e n -> Graph e n
-- actually, you can only insert a path into a graph,
-- because a path has one input and one output


-- should represent paths as list-like structures with these features:
-- succ node, pred node, expand node, fromList, toList
-- need fast lookup
-- could use Graph underneath, but restrict access functions
-- should specify order in type somehow, ie. make sure Call->Ret->APN doesn't happen



--- call graph ------
--- get all calls out of function

--- create call graph from those

--- get function starts
--- get all call instructions that call those functions