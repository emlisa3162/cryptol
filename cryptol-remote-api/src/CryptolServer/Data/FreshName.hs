
module CryptolServer.Data.FreshName
  ( FreshName
  , freshNameUnique
  , freshNameText
  , unsafeFreshName
  , unsafeToFreshName
  ) where


import Cryptol.ModuleSystem.Name (Name, nameUnique, nameIdent)
import Cryptol.Parser.AST (identText)
import Data.Text (Text)

-- | Minimal representative for fresh names generated by the server
-- when marshalling complex values back to the user. The `Int`
-- corresponds to the `nameUnique` of a `Name`, and the `Text`
-- is the non-infix `Ident`'s textual representation.
data FreshName = FreshName !Int !Text
  deriving (Eq, Show)

-- | Corresponds to the `nameUnique` field of a `Name`.
freshNameUnique :: FreshName -> Int
freshNameUnique (FreshName n _) = n

-- | Corresponds to the `nameIdent` field of a `Name` (except we know
-- if is not infix, so we just store the `Text`).
freshNameText :: FreshName -> Text
freshNameText (FreshName _ txt) = txt


-- | Get a `FreshName` which corresopnds to then given `Name`. N.B., this does
-- _not_ register any names with the server or ensure the ident is not infix,
-- and so should this function only be used by code which maintains
-- these invariants.
unsafeToFreshName :: Name -> FreshName
unsafeToFreshName nm = FreshName (nameUnique nm) (identText (nameIdent nm))

-- | Creates a FreshName -- users should take care to ensure any generated
-- `FreshName` has a mapping from `Int` to `FreshName` recorded in the server!
unsafeFreshName :: Int -> Text -> FreshName
unsafeFreshName n txt = FreshName n txt
