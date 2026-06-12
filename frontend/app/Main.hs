{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Miso
import qualified Miso.Html as H
import Miso.Lens

newtype Model = Model
  { _counter :: Int
  }
  deriving (Show, Eq)

counter :: Lens Model Int
counter = lens _counter $ \record field -> record {_counter = field}

data Action
  = AddOne
  | SubtractOne
  deriving (Show, Eq)

main :: IO ()
main = startApp defaultEvents app

#ifdef WASM
foreign export javascript "hs_start" main :: IO ()
#endif

app :: App Model Action
app = component emptyModel updateModel viewModel

emptyModel :: Model
emptyModel = Model 0

updateModel :: Action -> Effect parent props Model Action
updateModel = \case
  AddOne -> counter += 1
  SubtractOne -> counter -= 1

viewModel :: props -> Model -> View Model Action
viewModel _ m =
  H.div_
    []
    [ H.h1_ [] [text "Det virker — Miso + GHC WASM"]
    , H.button_ [H.onClick SubtractOne] [text "-"]
    , text (ms (m ^. counter))
    , H.button_ [H.onClick AddOne] [text "+"]
    ]
