module Blaze.Types.Pil.Op.ConstFloatOp where

-- This module is generated. Please use gen_pil_ops/Main.hs to modify.

import Blaze.Prelude

data ConstFloatOp expr = ConstFloatOp
  { constant :: Double
  } deriving (Eq, Ord, Show, Functor, Foldable, Traversable, Generic, FromJSON, ToJSON)

instance Hashable a => Hashable (ConstFloatOp a)