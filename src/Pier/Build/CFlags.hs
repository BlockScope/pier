{-# LANGUAGE DeriveAnyClass #-}
module Pier.Build.CFlags
    ( TransitiveDeps(..)
    , CFlags(..)
    , getCFlags
    , ghcDefines
    ) where

import Data.Semigroup
import Data.Set (Set)
import Development.Shake.Classes
import Distribution.PackageDescription
import Distribution.Text (display)
import Distribution.Version (versionNumbers)
import GHC.Generics (Generic(..))

import qualified Data.Set as Set

import Pier.Build.Stackage
import Pier.Core.Artifact

data TransitiveDeps = TransitiveDeps
    { transitiveDBs :: Set Artifact
    , transitiveLibFiles :: Set Artifact
    , transitiveIncludeDirs :: Set Artifact
    , transitiveDataFiles :: Set Artifact
    } deriving (Show, Eq, Typeable, Generic, Hashable, Binary, NFData)

instance Semigroup TransitiveDeps

instance Monoid TransitiveDeps where
    mempty = TransitiveDeps Set.empty Set.empty Set.empty Set.empty
    TransitiveDeps dbs files is datas
        `mappend` TransitiveDeps dbs' files' is' datas'
        = TransitiveDeps (dbs <> dbs') (files <> files') (is <> is')
                (datas <> datas')

-- TODO: macros file also
data CFlags = CFlags
    { ccFlags :: [String]
    , cppFlags :: [String]
    , cIncludeDirs :: Set Artifact
    , linkFlags :: [String]
    , linkLibs :: [String]
    }

-- TODO: include macros file too
getCFlags :: TransitiveDeps -> Artifact -> BuildInfo -> CFlags
getCFlags deps pkgDir bi =
    CFlags
            { ccFlags = ccOptions bi
            , cppFlags = cppOptions bi
            , cIncludeDirs =
                    Set.fromList (map (pkgDir />) $ includeDirs bi)
                    <> transitiveIncludeDirs deps
            , linkFlags = ldOptions bi
            , linkLibs = extraLibs bi
            }

-- | Definitions that GHC provides by default
ghcDefines :: InstalledGhc -> [String]
ghcDefines ghc = ["-D__GLASGOW_HASKELL__=" ++
                    cppVersion (ghcInstalledVersion ghc)]
  where
    cppVersion v = case versionNumbers v of
        (v1:v2:_) -> show v1 ++ if v2 < 10 then '0':show v2 else show v2
        _ -> error $ "cppVersion: " ++ display v


