module Globals exposing (Globals)

import Browser.Navigation as Nav
import Repo exposing (Repo)
import Session exposing (Session)


type alias Globals =
    { session : Session
    , repo : Repo
    , navKey : Nav.Key
    }
