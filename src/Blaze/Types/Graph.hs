module Blaze.Types.Graph where

import Blaze.Prelude

import qualified Data.Set as Set

type LEdge label node = (label, (node, node))

type Edge node = (node, node)


-- class Graph g where
--   type EdgeLabel g :: *
--   type Node g :: *
--   fromEdges :: [LEdge (EdgeLabel g) (Node g)] -> g
--   succs :: Node g -> g -> Set (Node g)
--   preds :: Node g -> g -> Set (Node g)
--   getEdgeLabel :: Edge (Node g) -> g -> Maybe (EdgeLabel g)
--   setEdgeLabel :: EdgeLabel g -> Edge (Node g) -> g -> g


-- findSimplePaths' :: (Graph g, Ord (Node g)) => Set (Node g) -> (Node g) -> (Node g) ->g -> [[Node g]]
-- findSimplePaths' seen start' end' g = fmap (start':) $ do
--   succ' <- Set.toList $ succs start' g `Set.difference` seen
--   if succ' == end'
--     then return [succ']
--     else findSimplePaths' (Set.insert succ' seen) succ' end' g
  
-- --- simple paths (non-repeating) from start to end
-- findSimplePaths :: (Graph g, Ord (Node g)) => Node g -> Node g -> g -> [[Node g]]
-- findSimplePaths = findSimplePaths' Set.empty

--------------------------
--------------------------

class Graph e n g | g -> e n where
  empty :: g
  fromNode :: n -> g
  fromEdges :: [(e, (n, n))] -> g
  succs :: n -> g -> Set n
  preds :: n -> g -> Set n
  nodes :: g -> Set n
  getEdgeLabel :: (n, n) -> g -> Maybe e
  setEdgeLabel :: e -> (n, n) -> g -> g
  removeEdge :: (n, n) -> g -> g
  removeNode :: n -> g -> g
  addEdge :: (e, (n, n)) -> g -> g
  -- add node/edges.. maybe overlay

class GraphFunctor g where
  mapEdges :: (e -> e') -> g e n -> g e' n
  mapNodes :: (n -> n') -> g e n -> g e n'


-- class ( EmptyGraph g
--       , BasicGraph node g
--       , EdgeGraph edge node g) => Graph edge node g

-- class EmptyGraph g where
--   empty :: g

-- class BasicGraph node g where
--   fromNode :: node -> g
--   succs :: node -> g -> Set node
--   preds :: node -> g -> Set node

-- class EdgeGraph edge node g where
--   fromEdges :: [(edge, (node, node))] -> g
--   getEdgeLabel :: (node, node) -> g -> Maybe edge
--   setEdgeLabel :: edge -> (node, node) -> g -> g

-- findSimplePaths' :: (BasicGraph n g, Ord n) => Set n -> n -> n -> g -> [[n]]
-- findSimplePaths' seen start' end' g = fmap (start':) $ do
--   succ' <- Set.toList $ succs start' g `Set.difference` seen
--   if succ' == end'
--     then return [succ']
--     else findSimplePaths' (Set.insert succ' seen) succ' end' g
  
-- --- simple paths (non-repeating) from start to end
-- findSimplePaths :: (BasicGraph n g, Ord n) => n -> n -> g -> [[n]]
-- findSimplePaths = findSimplePaths' Set.empty

--------------------------
--------------------------

-- class Graph g e n | g -> e n where
--   fromEdges :: [LEdge e n] -> g
--   succs :: n -> g -> Set n
--   preds :: n -> g -> Set n
--   getEdgeLabel :: Edge n -> g -> Maybe e
--   setEdgeLabel :: e -> Edge a -> g -> g

findNonRepeatPaths' :: (Graph e n g, Ord n) => Set n -> n -> g -> [[n]]
findNonRepeatPaths' seen start' g = do
  succ' <- Set.toList $ succs start' g `Set.difference` seen
  path <- findNonRepeatPaths' (Set.insert succ' seen) succ' g
  return $ succ':path

findNonRepeatPaths :: (Graph e n g, Ord n) => n -> g -> [[n]]
findNonRepeatPaths = findNonRepeatPaths' Set.empty

findSimplePaths' :: (Graph e n g, Ord n) => Set n -> n -> n -> g -> [[n]]
findSimplePaths' seen start' end' g = fmap (start':) $ do
  succ' <- Set.toList $ succs start' g `Set.difference` seen
  if succ' == end'
    then return [succ']
    else findSimplePaths' (Set.insert succ' seen) succ' end' g

findSimplePaths :: (Graph e node g, Ord node) => node -> node -> g -> [[node]]
findSimplePaths = findSimplePaths' Set.empty

findAllSimplePaths :: (Graph e node g, Ord node) => g -> [[node]]
findAllSimplePaths g = do
  src <- Set.toList $ sources g
  sink <- Set.toList $ sinks g
  findSimplePaths src sink g

sources :: Graph e n g => g -> Set n
sources g = Set.filter ((== 0) . Set.size . flip preds g) . nodes $ g

sinks :: Graph e n g => g -> Set n
sinks g = Set.filter ((== 0) . Set.size . flip succs g) . nodes $ g

removeEdges :: Graph e n g => [(n, n)] -> g -> g
removeEdges = flip $ foldr removeEdge

addEdges :: Graph e n g => [(e, (n, n))] -> g -> g
addEdges = flip $ foldr addEdge

reverseSpan :: Graph e n g => g -> Int -> n -> [[n]]
reverseSpan _ 0 node = [[node]]
reverseSpan g depth node = case Set.toList $ preds node g of
  [] -> [[node]]
  xs -> fmap (node:) . concatMap (reverseSpan g (depth - 1)) $ xs
  
