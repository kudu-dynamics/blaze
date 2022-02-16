{- HLINT ignore "Redundant do" -}

module Blaze.GraphSpec where

import Blaze.Prelude

import qualified Blaze.Types.Graph as G
import qualified Blaze.Graph as G
import qualified Blaze.Types.Graph.Alga as GA
import qualified Data.HashSet as HashSet
import qualified Data.HashMap.Strict as HashMap
import Test.Hspec

spec :: Spec
spec = describe "Blaze.Graph" $ do
  let toLedge = G.fromTupleLEdge . ((),)
  context "getPostDominators_" $ do
    it "should get empty PostDominators for singleton graph" $ do
      let g :: GA.AlgaGraph () () Text
          g = G.fromNode "a"
          termNode = "a"
          expected = G.PostDominators . HashMap.fromList $ []
          
      G.getPostDominators_ termNode g `shouldBe` expected

    it "should get single PostDominator for graph with one edge" $ do
      let g :: GA.AlgaGraph () () Text
          g = G.fromEdges . fmap toLedge $
            [("a", "b")]
          termNode = "b"
          expected = G.PostDominators . HashMap.fromList $
            [("a", HashSet.fromList ["b"])]
          
      G.getPostDominators_ termNode g `shouldBe` expected

    it "should get empty PostDominator when root node is supplied as term node" $ do
      let g :: GA.AlgaGraph () () Text
          g = G.fromEdges . fmap toLedge $
            [("a", "b")]
          termNode = "a"
          expected = G.PostDominators . HashMap.fromList $ []
          
      G.getPostDominators_ termNode g `shouldBe` expected

    it "should get two PostDominator entries for two-to-one graph" $ do
      let g :: GA.AlgaGraph () () Text
          g = G.fromEdges . fmap toLedge $
            [ ("a", "c")
            , ("b", "c")
            ]
          termNode = "c"
          expected = G.PostDominators . HashMap.fromList $
            [ ("a", HashSet.fromList ["c"])
            , ("b", HashSet.fromList ["c"])
            ]
          
      G.getPostDominators_ termNode g `shouldBe` expected

  context "getPostDominators" $ do
    let dummyTermNode = "z"
        dummyTermEdgeLabel = ()
        getPostDominators = G.getPostDominators dummyTermNode dummyTermEdgeLabel

    it "should get empty PostDominators for singleton graph" $ do
      let g :: GA.AlgaGraph () () Text
          g = G.fromNode "a"
          expected = G.PostDominators . HashMap.fromList $ []
          
      getPostDominators g `shouldBe` expected

    it "should get single PostDominator for graph with one edge" $ do
      let g :: GA.AlgaGraph () () Text
          g = G.fromEdges . fmap toLedge $
            [("a", "b")]
          expected = G.PostDominators . HashMap.fromList $
            [("a", HashSet.fromList ["b"])]
          
      getPostDominators g `shouldBe` expected

    it "should get two PostDominator entries for two-to-one graph" $ do
      let g :: GA.AlgaGraph () () Text
          g = G.fromEdges . fmap toLedge $
            [ ("a", "c")
            , ("b", "c")
            ]
          expected = G.PostDominators . HashMap.fromList $
            [ ("a", HashSet.fromList ["c"])
            , ("b", HashSet.fromList ["c"])
            ]
          
      getPostDominators g `shouldBe` expected

    it "should find post dominators when graphs have multiple term nodes" $ do
      let g :: GA.AlgaGraph () () Text
          g = G.fromEdges . fmap toLedge $
            [ ("a", "c")
            , ("c", "e")
            , ("c", "f")
            , ("b", "d")
            , ("d", "f")
            ]
          expected = G.PostDominators . HashMap.fromList $
            [ ("a", HashSet.fromList ["c"])
            , ("b", HashSet.fromList ["d", "f"])
            , ("d", HashSet.fromList ["f"])
            ]
          
      getPostDominators g `shouldBe` expected

    it "should find post dominators for double diamond graph" $ do
      let g :: GA.AlgaGraph () () Text
          g = G.fromEdges . fmap toLedge $
            [ ("a", "b1")
            , ("a", "b2")
            , ("b1", "c")
            , ("b2", "c")
            , ("c", "d1")
            , ("c", "d2")
            , ("d1", "e")
            , ("d2", "e")
            ]
          expected = G.PostDominators . HashMap.fromList $
            [ ("a", HashSet.fromList ["c", "e"])
            , ("b1", HashSet.fromList ["c", "e"])
            , ("b2", HashSet.fromList ["c", "e"])
            , ("c", HashSet.fromList ["e"])
            , ("d1", HashSet.fromList ["e"])
            , ("d2", HashSet.fromList ["e"])
            ]

      getPostDominators g `shouldBe` expected