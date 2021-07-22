-- |
-- Module      :  Cryptol.ModuleSystem.Env
-- Copyright   :  (c) 2013-2016 Galois, Inc.
-- License     :  BSD3
-- Maintainer  :  cryptol@galois.com
-- Stability   :  provisional
-- Portability :  portable

{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}
module Cryptol.ModuleSystem.Env where

#ifndef RELOCATABLE
import Paths_cryptol (getDataDir)
#endif

import Cryptol.Eval (EvalEnv)
import Cryptol.ModuleSystem.Fingerprint
import Cryptol.ModuleSystem.Interface
import Cryptol.ModuleSystem.Name (Name,Supply,emptySupply)
import qualified Cryptol.ModuleSystem.NamingEnv as R
import Cryptol.Parser.AST
import qualified Cryptol.TypeCheck as T
import qualified Cryptol.TypeCheck.Interface as T
import qualified Cryptol.TypeCheck.AST as T
import Cryptol.Utils.PP (PP(..),text,parens,NameDisp)

import Data.ByteString(ByteString)
import Control.Monad (guard,mplus)
import qualified Control.Exception as X
import Data.Function (on)
import Data.Set(Set)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Semigroup
import System.Directory (getAppUserDataDirectory, getCurrentDirectory)
import System.Environment(getExecutablePath)
import System.FilePath ((</>), normalise, joinPath, splitPath, takeDirectory)
import qualified Data.List as List

import GHC.Generics (Generic)
import Control.DeepSeq

import Prelude ()
import Prelude.Compat

import Cryptol.Utils.Panic(panic)
import Cryptol.Utils.PP(pp)

-- Module Environment ----------------------------------------------------------

-- | This is the current state of the interpreter.
data ModuleEnv = ModuleEnv
  { meLoadedModules :: LoadedModules
    -- ^ Information about all loaded modules.  See 'LoadedModule'.
    -- Contains information such as the file where the module was loaded
    -- from, as well as the module's interface, used for type checking.

  , meNameSeeds     :: T.NameSeeds
    -- ^ A source of new names for the type checker.

  , meEvalEnv       :: EvalEnv
    -- ^ The evaluation environment.  Contains the values for all loaded
    -- modules, both public and private.

  , meCoreLint      :: CoreLint
    -- ^ Should we run the linter to ensure sanity.

  , meMonoBinds     :: !Bool
    -- ^ Are we assuming that local bindings are monomorphic.
    -- XXX: We should probably remove this flag, and set it to 'True'.



  , meFocusedModule :: Maybe ModName
    -- ^ The "current" module.  Used to decide how to print names, for example.

  , meSearchPath    :: [FilePath]
    -- ^ Where we look for things.

  , meDynEnv        :: DynamicEnv
    -- ^ This contains additional definitions that were made at the command
    -- line, and so they don't reside in any module.

  , meSupply        :: !Supply
    -- ^ Name source for the renamer

  } deriving Generic

instance NFData ModuleEnv where
  rnf x = meLoadedModules x `seq` meEvalEnv x `seq` meDynEnv x `seq` ()

-- | Should we run the linter?
data CoreLint = NoCoreLint        -- ^ Don't run core lint
              | CoreLint          -- ^ Run core lint
  deriving (Generic, NFData)

resetModuleEnv :: ModuleEnv -> ModuleEnv
resetModuleEnv env = env
  { meLoadedModules = mempty
  , meNameSeeds     = T.nameSeeds
  , meEvalEnv       = mempty
  , meFocusedModule = Nothing
  , meDynEnv        = mempty
  }

initialModuleEnv :: IO ModuleEnv
initialModuleEnv = do
  curDir <- getCurrentDirectory
#ifndef RELOCATABLE
  dataDir <- getDataDir
#endif
  binDir <- takeDirectory `fmap` getExecutablePath
  let instDir = normalise . joinPath . init . splitPath $ binDir
  -- looking up this directory can fail if no HOME is set, as in some
  -- CI settings
  let handle :: X.IOException -> IO String
      handle _e = return ""
  userDir <- X.catch (getAppUserDataDirectory "cryptol") handle
  let searchPath = [ curDir
                   -- something like $HOME/.cryptol
                   , userDir
#if defined(mingw32_HOST_OS) || defined(__MINGW32__)
                   -- ../cryptol on win32
                   , instDir </> "cryptol"
#else
                   -- ../share/cryptol on others
                   , instDir </> "share" </> "cryptol"
#endif

#ifndef RELOCATABLE
                   -- Cabal-defined data directory. Since this
                   -- is usually a global location like
                   -- /usr/local, search this one last in case
                   -- someone has multiple Cryptols
                   , dataDir
#endif
                   ]

  return ModuleEnv
    { meLoadedModules = mempty
    , meNameSeeds     = T.nameSeeds
    , meEvalEnv       = mempty
    , meFocusedModule = Nothing
      -- we search these in order, taking the first match
    , meSearchPath    = searchPath
    , meDynEnv        = mempty
    , meMonoBinds     = True
    , meCoreLint      = NoCoreLint
    , meSupply        = emptySupply
    }

-- | Try to focus a loaded module in the module environment.
focusModule :: ModName -> ModuleEnv -> Maybe ModuleEnv
focusModule n me = do
  guard (isLoaded n (meLoadedModules me))
  return me { meFocusedModule = Just n }

-- | Get a list of all the loaded modules. Each module in the
-- resulting list depends only on other modules that precede it.
-- Note that this includes parameterized modules.
loadedModules :: ModuleEnv -> [T.Module]
loadedModules = map lmModule . getLoadedModules . meLoadedModules

-- | Get a list of all the loaded non-parameterized modules.
-- These are the modules that can be used for evaluation, proving etc.
loadedNonParamModules :: ModuleEnv -> [T.Module]
loadedNonParamModules = map lmModule . lmLoadedModules . meLoadedModules

loadedNewtypes :: ModuleEnv -> Map Name IfaceNewtype
loadedNewtypes menv = Map.unions
   [ ifNewtypes (ifPublic i) <> ifNewtypes (ifPrivate i)
   | i <- map lmInterface (getLoadedModules (meLoadedModules menv))
   ]

-- | Are any parameterized modules loaded?
hasParamModules :: ModuleEnv -> Bool
hasParamModules = not . null . lmLoadedParamModules . meLoadedModules

allDeclGroups :: ModuleEnv -> [T.DeclGroup]
allDeclGroups = concatMap T.mDecls . loadedNonParamModules

-- | Contains enough information to browse what's in scope,
-- or type check new expressions.
data ModContext = ModContext
  { mctxParams          :: IfaceParams
  , mctxExported        :: Set Name
  , mctxDecls           :: IfaceDecls
    -- ^ Should contain at least names in NamingEnv, but may have more
  , mctxNames           :: R.NamingEnv
    -- ^ What's in scope inside the module
  , mctxNameDisp        :: NameDisp
  }

-- This instance is a bit bogus.  It is mostly used to add the dynamic
-- environemnt to an existing module, and it makes sense for that use case.
instance Semigroup ModContext where
  x <> y = ModContext { mctxParams   = jnParams (mctxParams x) (mctxParams y)
                      , mctxExported = mctxExported x <> mctxExported y
                      , mctxDecls    = mctxDecls x  <> mctxDecls  y
                      , mctxNames    = names
                      , mctxNameDisp = R.toNameDisp names
                      }

      where
      names = mctxNames x `R.shadowing` mctxNames y
      jnParams a b
        | isEmptyIfaceParams a = b
        | isEmptyIfaceParams b = a
        | otherwise =
          panic "ModContext" [ "Cannot combined 2 parameterized contexts" ]

instance Monoid ModContext where
  mempty = ModContext { mctxParams   = noIfaceParams
                      , mctxDecls    = mempty
                      , mctxExported = mempty
                      , mctxNames    = mempty
                      , mctxNameDisp = R.toNameDisp mempty
                      }



modContextOf :: ModName -> ModuleEnv -> Maybe ModContext
modContextOf mname me =
  do lm <- lookupModule mname me
     let localIface  = lmInterface lm
         localNames  = lmNamingEnv lm
         loadedDecls = map (ifPublic . lmInterface)
                     $ getLoadedModules (meLoadedModules me)
     pure ModContext
       { mctxParams   = ifParams localIface
       , mctxExported = ifaceDeclsNames (ifPublic localIface)
       , mctxDecls    = mconcat (ifPrivate localIface : loadedDecls)
       , mctxNames    = localNames
       , mctxNameDisp = R.toNameDisp localNames
       }

dynModContext :: ModuleEnv -> ModContext
dynModContext me = mempty { mctxNames    = dynNames
                          , mctxNameDisp = R.toNameDisp dynNames
                          , mctxDecls    = deIfaceDecls (meDynEnv me)
                          }
  where dynNames = deNames (meDynEnv me)




-- | Given the state of the environment, compute information about what's
-- in scope on the REPL.  This includes what's in the focused module, plus any
-- additional definitions from the REPL (e.g., let bound names, and @it@).
focusedEnv :: ModuleEnv -> ModContext
focusedEnv me =
  case meFocusedModule me of
    Nothing -> dynModContext me
    Just fm -> case modContextOf fm me of
                 Just c -> dynModContext me <> c
                 Nothing -> panic "focusedEnv"
                              [ "Focused modules not loaded: " ++ show (pp fm) ]
  

-- Loaded Modules --------------------------------------------------------------

-- | The location of a module
data ModulePath = InFile FilePath
                | InMem String ByteString -- ^ Label, content
    deriving (Show, Generic, NFData)

-- | In-memory things are compared by label.
instance Eq ModulePath where
  p1 == p2 =
    case (p1,p2) of
      (InFile x, InFile y) -> x == y
      (InMem a _, InMem b _) -> a == b
      _ -> False

instance PP ModulePath where
  ppPrec _ e =
    case e of
      InFile p  -> text p
      InMem l _ -> parens (text l)



-- | The name of the content---either the file path, or the provided label.
modulePathLabel :: ModulePath -> String
modulePathLabel p =
  case p of
    InFile path -> path
    InMem lab _ -> lab



data LoadedModules = LoadedModules
  { lmLoadedModules      :: [LoadedModule]
    -- ^ Invariants:
    -- 1) All the dependencies of any module `m` must precede `m` in the list.
    -- 2) Does not contain any parameterized modules.

  , lmLoadedParamModules :: [LoadedModule]
    -- ^ Loaded parameterized modules.

  } deriving (Show, Generic, NFData)

getLoadedModules :: LoadedModules -> [LoadedModule]
getLoadedModules x = lmLoadedParamModules x ++ lmLoadedModules x

instance Semigroup LoadedModules where
  l <> r = LoadedModules
    { lmLoadedModules = List.unionBy ((==) `on` lmName)
                                      (lmLoadedModules l) (lmLoadedModules r)
    , lmLoadedParamModules = lmLoadedParamModules l ++ lmLoadedParamModules r }

instance Monoid LoadedModules where
  mempty = LoadedModules { lmLoadedModules = []
                         , lmLoadedParamModules = []
                         }
  mappend l r = l <> r

data LoadedModule = LoadedModule
  { lmName              :: ModName
    -- ^ The name of this module.  Should match what's in 'lmModule'

  , lmFilePath          :: ModulePath
    -- ^ The file path used to load this module (may not be canonical)

  , lmModuleId          :: String
    -- ^ An identifier used to identify the source of the bytes for the module.
    -- For files we just use the cononical path, for in memory things we
    -- use their label.

  , lmNamingEnv         :: !R.NamingEnv
    -- ^ What's in scope in this module

  , lmInterface         :: Iface
    -- ^ The module's interface.

  , lmModule            :: T.Module
    -- ^ The actual type-checked module

  , lmFingerprint       :: Fingerprint
  } deriving (Show, Generic, NFData)

-- | Has this module been loaded already.
isLoaded :: ModName -> LoadedModules -> Bool
isLoaded mn lm = any ((mn ==) . lmName) (getLoadedModules lm)

-- | Is this a loaded parameterized module.
isLoadedParamMod :: ModName -> LoadedModules -> Bool
isLoadedParamMod mn ln = any ((mn ==) . lmName) (lmLoadedParamModules ln)

-- | Try to find a previously loaded module
lookupModule :: ModName -> ModuleEnv -> Maybe LoadedModule
lookupModule mn me = search lmLoadedModules `mplus` search lmLoadedParamModules
  where
  search how = List.find ((mn ==) . lmName) (how (meLoadedModules me))


-- | Add a freshly loaded module.  If it was previously loaded, then
-- the new version is ignored.
addLoadedModule ::
  ModulePath -> String -> Fingerprint -> R.NamingEnv -> T.Module ->
  LoadedModules -> LoadedModules
addLoadedModule path ident fp nameEnv tm lm
  | isLoaded (T.mName tm) lm  = lm
  | T.isParametrizedModule tm = lm { lmLoadedParamModules = loaded :
                                                lmLoadedParamModules lm }
  | otherwise                = lm { lmLoadedModules =
                                          lmLoadedModules lm ++ [loaded] }
  where
  loaded = LoadedModule
    { lmName            = T.mName tm
    , lmFilePath        = path
    , lmModuleId        = ident
    , lmNamingEnv       = nameEnv
    , lmInterface       = T.genIface tm
    , lmModule          = tm
    , lmFingerprint     = fp
    }

-- | Remove a previously loaded module.
-- Note that this removes exactly the modules specified by the predicate.
-- One should be carfule to preserve the invariant on 'LoadedModules'.
removeLoadedModule :: (LoadedModule -> Bool) -> LoadedModules -> LoadedModules
removeLoadedModule rm lm =
  LoadedModules
    { lmLoadedModules = filter (not . rm) (lmLoadedModules lm)
    , lmLoadedParamModules = filter (not . rm) (lmLoadedParamModules lm)
    }

-- Dynamic Environments --------------------------------------------------------

-- | Extra information we need to carry around to dynamically extend
-- an environment outside the context of a single module. Particularly
-- useful when dealing with interactive declarations as in @let@ or
-- @it@.
data DynamicEnv = DEnv
  { deNames :: R.NamingEnv
  , deDecls :: [T.DeclGroup]
  , deEnv   :: EvalEnv
  } deriving Generic

instance Semigroup DynamicEnv where
  de1 <> de2 = DEnv
    { deNames = deNames de1 <> deNames de2
    , deDecls = deDecls de1 <> deDecls de2
    , deEnv   = deEnv   de1 <> deEnv   de2
    }

instance Monoid DynamicEnv where
  mempty = DEnv
    { deNames = mempty
    , deDecls = mempty
    , deEnv   = mempty
    }
  mappend de1 de2 = de1 <> de2

-- | Build 'IfaceDecls' that correspond to all of the bindings in the
-- dynamic environment.
--
-- XXX: if we ever add type synonyms or newtypes at the REPL, revisit
-- this.
deIfaceDecls :: DynamicEnv -> IfaceDecls
deIfaceDecls DEnv { deDecls = dgs } =
  mconcat [ IfaceDecls
            { ifTySyns   = Map.empty
            , ifNewtypes = Map.empty
            , ifAbstractTypes = Map.empty
            , ifDecls    = Map.singleton (ifDeclName ifd) ifd
            , ifModules  = Map.empty
            , ifSignatures = Map.empty
            }
          | decl <- concatMap T.groupDecls dgs
          , let ifd = T.mkIfaceDecl decl
          ]
