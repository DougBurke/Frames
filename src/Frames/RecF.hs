{-# LANGUAGE ConstraintKinds,
             DataKinds,
             FlexibleContexts,
             FlexibleInstances,
             GADTs,
             KindSignatures,
             MultiParamTypeClasses,
             PatternSynonyms,
             RankNTypes,
             ScopedTypeVariables,
             TypeFamilies,
             TypeOperators,
             ViewPatterns #-}
module Frames.RecF (RecF, V.rappend, V.rtraverse, rdel, CanDelete,
                    frameCons, pattern (:&), pattern Nil, AllCols,
                    UnColumn, AsVinyl(..), mapMono, mapMethod,
                    ShowRecF, showRecF, ColFun, ColumnHeaders, 
                    columnHeaders) where
import Control.Applicative ((<$>))
import Data.List (intercalate)
import Data.Proxy
import qualified Data.Vinyl as V
import Data.Vinyl.Functor (Identity)
import Data.Vinyl.TypeLevel
import Frames.Col
import Frames.TypeLevel
import GHC.TypeLits (KnownSymbol, symbolVal)

-- | A record parameterized by a functor. This can be useful for
-- distributing an effect across a record. For instance, a per-element
-- validation can be pulled out to act as a per-record validation.
type RecF = V.Rec

-- | Add a column to the head of a row.
frameCons :: Functor f => f a -> V.Rec f rs -> V.Rec f (s :-> a ': rs)
frameCons = (V.:&) . fmap Col
{-# INLINE frameCons #-}

-- | Separate the first element of a row from the rest of the row.
frameUncons :: Functor f => V.Rec f (s :-> r ': rs) -> (f r, V.Rec f rs)
frameUncons (x V.:& xs) = (fmap getCol x, xs)
{-# INLINE frameUncons #-}

pattern Nil = V.RNil
pattern x :& xs <- (frameUncons -> (x, xs))

-- NOTE: A bidirectional pattern synonym would be great, but we'll
-- have to wait for GHC 7.10 to gain wide acceptance before depending
-- upon its availability.

class ColumnHeaders (cs::[*]) where
  -- | Return the column names for a record.
  columnHeaders :: proxy (RecF f cs) -> [String]

instance ColumnHeaders '[] where
  columnHeaders _ = []

instance forall cs s c. (ColumnHeaders cs, KnownSymbol s)
    => ColumnHeaders (s :-> c ': cs) where
  columnHeaders _ = symbolVal (Proxy::Proxy s) : columnHeaders (Proxy::Proxy (RecF f cs))

-- | A type function to convert a 'Rec' to a 'RecF'. @ColFun f (Rec
-- rs) = RecF f rs@.
type family ColFun f x where
  ColFun f (RecF Identity rs) = RecF f rs

-- | Strip the column information from each element of a list of
-- types.
type family UnColumn ts where
  UnColumn '[] = '[]
  UnColumn ((s :-> t) ': ts) = t ': UnColumn ts

-- | Enforce a constraint on the payload type of each column.
type AllCols c ts = LAll c (UnColumn ts)

-- | Remove the column name phantom types from a record, leaving you
-- with an unadorned Vinyl 'V.Rec'.
class AsVinyl ts where
  toVinyl :: Functor f => RecF f ts -> V.Rec f (UnColumn ts)
  fromVinyl :: Functor f => V.Rec f (UnColumn ts) -> RecF f ts

instance AsVinyl '[] where
  toVinyl _ = V.RNil
  fromVinyl _ = V.RNil

instance AsVinyl ts => AsVinyl (s :-> t ': ts) where
  toVinyl (x V.:& xs) = fmap getCol x V.:& toVinyl xs
  fromVinyl (x V.:& xs) = fmap Col x V.:& fromVinyl xs
  fromVinyl _ = error "GHC coverage checker isn't great"

-- | Map a function across a homogeneous, monomorphic 'V.Rec'.
mapMonoV :: (Functor f, AllAre a ts) => (a -> a) -> V.Rec f ts -> V.Rec f ts
mapMonoV _ V.RNil = V.RNil
mapMonoV f (x V.:& xs) = fmap f x V.:& mapMonoV f xs

-- | Map a function across a homogeneous, monomorphic 'RecF'.
mapMono :: (AllAre a (UnColumn ts), Functor f, AsVinyl ts)
        => (a -> a) -> RecF f ts -> RecF f ts
mapMono f = fromVinyl . mapMonoV f . toVinyl

-- | Map a typeclass method across a 'V.Rec' each of whose fields
-- have instances of the typeclass.
mapMethodV :: forall c f ts. (Functor f, LAll c ts)
           => Proxy c -> (forall a. c a => a -> a) -> V.Rec f ts -> V.Rec f ts
mapMethodV _ f = go
  where go :: LAll c ts' => V.Rec f ts' -> V.Rec f ts'
        go V.RNil = V.RNil
        go (x V.:& xs) = fmap f x V.:& go xs

-- | Map a typeclass method across a 'RecF' each of whose fields
-- has an instance of the typeclass.
mapMethod :: forall f c ts. (Functor f, LAll c (UnColumn ts), AsVinyl ts)
          => Proxy c -> (forall a. c a => a -> a) -> RecF f ts -> RecF f ts
mapMethod p f = fromVinyl . mapMethodV p f . toVinyl

-- | A constraint that a field can be deleted from a record.
type CanDelete r rs = (V.RElem r rs (RIndex r rs), RDelete r rs V.⊆ rs)

-- | Delete a field from a record
rdel :: CanDelete r rs => proxy r -> RecF f rs -> RecF f (RDelete r rs)
rdel _ = V.rcast

-- | The ability to pretty print a 'RecF''s fields.
class Functor f => ShowRecF f rs where
  showRecF' :: RecF f rs -> [String]

instance Functor f => ShowRecF f '[] where
  showRecF' _ = []

instance forall s f a rs. (KnownSymbol s, Show (f (Col' s a)), ShowRecF f rs)
  => ShowRecF f (s :-> a ': rs) where
  showRecF' (x :& xs) = show (col' <$> x :: f (Col' s a)) : showRecF' xs
  showRecF' _ = error "GHC coverage error"

-- | Pretty printing of 'RecF' values.
showRecF :: ShowRecF f rs => RecF f rs -> String
showRecF r = "{" ++ intercalate ", " (showRecF' r) ++ "}"
