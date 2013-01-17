{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Text.Trifecta.Highlight
-- Copyright   :  (C) 2011 Edward Kmett
-- License     :  BSD-style (see the file LICENSE)
--
-- Maintainer  :  Edward Kmett <ekmett@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable
--
----------------------------------------------------------------------------
module Text.Trifecta.Highlight
  ( Highlight
  , HighlightedRope(HighlightedRope)
  , HasHighlightedRope(..)
  , withHighlight
  , HighlightDoc(HighlightDoc)
  , HasHighlightDoc(..)
  , doc
  ) where

import Control.Lens
import Data.Foldable as F
import Data.Int (Int64)
import Data.Key hiding ((!))
import Data.List (sort)
import Data.Semigroup
import Data.Semigroup.Union
import Prelude hiding (head)
import Text.Blaze
import Text.Blaze.Html5 hiding (a,b,i)
import qualified Text.Blaze.Html5 as Html5
import Text.Blaze.Html5.Attributes hiding (title,id)
import Text.Blaze.Internal
import Text.Parser.Token.Highlight
import Text.PrettyPrint.ANSI.Leijen hiding ((<>))
import Text.Trifecta.Util.IntervalMap as IM
import Text.Trifecta.Delta
import Text.Trifecta.Rope
import qualified Data.ByteString.Lazy.Char8 as L
import qualified Data.ByteString.Lazy.UTF8 as LazyUTF8

withHighlight :: Highlight -> Doc -> Doc
withHighlight Comment                     = blue
withHighlight ReservedIdentifier          = magenta
withHighlight ReservedConstructor         = magenta
withHighlight EscapeCode                  = magenta
withHighlight Operator                    = yellow
withHighlight CharLiteral                 = cyan
withHighlight StringLiteral               = cyan
withHighlight Constructor                 = bold
withHighlight ReservedOperator            = yellow
withHighlight ConstructorOperator         = yellow
withHighlight ReservedConstructorOperator = yellow
withHighlight _                           = id

{-
pushToken, popToken :: Highlight -> Doc
pushToken h = Prelude.foldr (\x b -> pure (Push x) <> b) mempty (withHighlight h)
popToken h  = Prelude.foldr (\_ b -> pure Pop      <> b) mempty (withHighlight h)
-}

data HighlightedRope = HighlightedRope
  { _ropeHighlights :: !(IM.IntervalMap Delta Highlight)
  , _ropeContent    :: {-# UNPACK #-} !Rope
  }

makeClassy ''HighlightedRope

instance HasDelta HighlightedRope where
  delta = delta . _ropeContent

instance HasBytes HighlightedRope where
  bytes = bytes . _ropeContent

instance Semigroup HighlightedRope where
  HighlightedRope h bs <> HighlightedRope h' bs' = HighlightedRope (h `union` IM.offset (delta bs) h') (bs <> bs')

instance Monoid HighlightedRope where
  mappend = (<>)
  mempty = HighlightedRope mempty mempty

data Located a = a :@ {-# UNPACK #-} !Int64
infix 5 :@
instance Eq (Located a) where
  _ :@ m == _ :@ n = m == n
instance Ord (Located a) where
  compare (_ :@ m) (_ :@ n) = compare m n

instance ToMarkup HighlightedRope where
  toMarkup (HighlightedRope intervals r) = Html5.pre $ go 0 lbs effects where
    lbs = L.fromChunks [bs | Strand bs _ <- F.toList (strands r)]
    ln no = Html5.a ! name (toValue $ "line-" ++ show no) $ Empty
    effects = sort $ [ i | (Interval lo hi, tok) <- intersections mempty (delta r) intervals
                     , i <- [ (Leaf "span" "<span" ">" ! class_ (toValue $ show tok)) :@ bytes lo
                            , preEscapedString "</span>" :@ bytes hi
                            ]
                     ] ++ mapWithKey (\k i -> ln k :@ i) (L.elemIndices '\n' lbs)
    go _ cs [] = unsafeLazyByteString cs
    go b cs ((eff :@ eb) : es)
      | eb <= b = eff >> go b cs es
      | otherwise = unsafeLazyByteString om >> go eb nom es
         where (om,nom) = L.splitAt (fromIntegral (eb - b)) cs

instance Pretty HighlightedRope where
  pretty (HighlightedRope _intervals r) = go 0 lbs effects where
    lbs = L.fromChunks [bs | Strand bs _ <- F.toList (strands r)]
    effects = error "pretty HighlightRope effects"
{-
    effects = sort $ [ i | (Interval lo hi, tok) <- intersections mempty (delta r) intervals
                     , i <- [ pushToken tok :@ bytes lo
                            , popToken tok  :@ bytes hi
                            ]
                     ]
-}
    go _ cs [] = pretty (LazyUTF8.toString cs)
    go b cs ((eff :@ eb) : es)
      | eb <= b = eff <> go b cs es
      | otherwise = pretty (LazyUTF8.toString om) <> go eb nom es
         where (om,nom) = L.splitAt (fromIntegral (eb - b)) cs

-- | Represents a source file like an HsColour rendered document
data HighlightDoc = HighlightDoc
  { _docTitle   :: String
  , _docCss     :: String -- href for the css file
  , _docContent :: HighlightedRope
  }

makeClassy ''HighlightDoc

doc :: String -> HighlightedRope -> HighlightDoc
doc t r = HighlightDoc t "trifecta.css" r

instance ToMarkup HighlightDoc where
  toMarkup (HighlightDoc t css cs) = docTypeHtml $ do
    head $ do
      preEscapedString "<!-- Generated by trifecta, http://github.com/ekmett/trifecta/ -->\n"
      title $ toHtml t
      link ! rel "stylesheet" ! type_ "text/css" ! href (toValue css)
    body $ toHtml cs

{-
newtype Highlighter m a = Highlighter { runHighlighter :: IntervalMap Map Highlight -> m (a, IntervalMap Map Highlight) }
  deriving (Functor)

instance (Functor m, Monad m) => Applicative (Highlighter m) where
  (<*>) = ap
  pure = return

instance (Functor m, MonadPlus m) => Alternative (Highlighter m) where
  (<|>) = mplus
  empty = mzero

instance Monad m => Monad (Highlighter m) where
  return a = Highlighter $ \s -> return (a, s)
  Highlighter m >>= f = Highlighter $ \s -> m s >>= \(a, s') -> runHighlighter (f a) s'

instance MonadTrans Highlighter where
  lift m = Highlighter $ \s -> fmap (\a -> (a,s)) m

instance MonadPlus m => MonadPlus (Highlighter m) where
  mplus (Highlighter m) (Highligher n) = Highlighter $ \s -> m s `mplus` n s
  mzero = Highlighter $ const mzero

-- instance Parsing m => Parsing (Highlighter m) where
-}
