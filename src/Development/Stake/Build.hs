{-# LANGUAGE DeriveAnyClass #-}
{-# OPTIONS_GHC -Wno-orphans #-}
module Development.Stake.Build
    ( buildPackageRules
    , askBuiltPackages
    )
    where

import Data.List.NonEmpty (NonEmpty(..))
import Data.Semigroup
import GHC.Generics hiding (packageName)
import Control.Monad (void)
import qualified Data.HashMap.Strict as HM
import Development.Shake
import Development.Shake.Classes
import Development.Shake.FilePath
import Development.Stake.Core
import Development.Stake.Package
import Development.Stake.Stackage
import Development.Stake.Witness
import Distribution.Compiler
import Distribution.Package
import Distribution.PackageDescription
import Distribution.PackageDescription.Parse
import Distribution.System (buildOS, buildArch)
import Distribution.Verbosity (normal)
import Distribution.Version (withinRange)
import qualified Data.HashSet as HS

{-
Outline:

downloads/stackage/plan/*.yaml
downloads/hackage/split-1.2.3 for downloaded and unpacked
build/lts-9.6/split/
    bin/{executable-name}
    pkgdb/package.conf
    pkgdb/**/*.hi
    pkgdb/*.a

-}

{-
Plan changes shared between snapshots:
built package gets a hash
and asking for one involves passing all the flags and deps
that it got, including their hashes


-}

instance Hashable FlagName

buildPackageRules :: Rules ()
buildPackageRules = addWitness buildPackage

data ResolvePackageO = ResolvePackageO PlanName PackageName
    deriving (Show,Typeable,Eq,Generic)

instance Hashable ResolvePackageO
instance Binary ResolvePackageO
instance NFData ResolvePackageO
type instance RuleResult ResolvePackageO = Resolved

data BuiltPackageR = BuiltPackageR PlanName Resolved
    deriving (Show,Typeable,Eq,Generic)
instance Hashable BuiltPackageR
instance Binary BuiltPackageR
instance NFData BuiltPackageR
type instance RuleResult BuiltPackageR = BuiltPackage

-- ghc --package-db .stake/...text-1234.pkg/db --package text-1234
data BuiltPackage = BuiltPackage
                        { builtTransitiveDBs :: HS.HashSet FilePath
                        , builtPackageName :: PackageName
                        }
    deriving (Show,Typeable,Eq,Hashable,Binary,NFData,Generic)

newtype BuildPlanDir = BuildPlanDir { unBuildPlanDir :: FilePath }

buildPlanDir :: PlanName -> BuildPlanDir
buildPlanDir (PlanName n) = BuildPlanDir $ buildArtifact $ n </> "packages"

askBuiltPackages :: PlanName -> [PackageName] -> Action [BuiltPackage]
askBuiltPackages planName pkgs = do
    plan <- askBuildPlan planName
    askWitnesses
        $ map (BuiltPackageR planName . resolvePackage plan)
        $ pkgs

buildPackage :: BuiltPackageR -> Action BuiltPackage
buildPackage (BuiltPackageR plan r) = do
    rerunIfCleaned
    buildResolved plan r

buildResolved :: PlanName -> Resolved -> Action BuiltPackage
buildResolved _ (Resolved Builtin p) = do
    putNormal $ "Built-in " ++ show (packageIdString p)
    return BuiltPackage { builtTransitiveDBs = HS.empty
                        , builtPackageName = packageName p
                        }
buildResolved planName (Resolved Additional p) = do
    let n = packageIdString p
    -- TODO: what if the .cabal file has a different basename?
    -- Maybe make this a witness too.
    let f = artifact $ "downloads/hackage" </> n
                            </> unPackageName (pkgName p)
                            <.> "cabal"
    need [f]
    gdesc <- liftIO $ readPackageDescription normal f
    plan <- askBuildPlan planName
    desc <- flattenToDefaultFlags plan gdesc
    buildFromDesc planName desc

flattenToDefaultFlags
    :: BuildPlan -> GenericPackageDescription -> Action PackageDescription
flattenToDefaultFlags plan gdesc = do
    let desc0 = packageDescription gdesc
    let flags = HM.fromList [(flagName f, flagDefault f)
                        | f <- genPackageFlags gdesc
                        ]
    return desc0 {
        -- TODO: Nothing vs Nothing?
        library = fmap (resolve plan flags) $ condLibrary gdesc
       }

resolve
    :: Semigroup a
    => BuildPlan
    -> HM.HashMap FlagName Bool
    -> CondTree ConfVar [Dependency] a
    -> a
resolve plan flags node
    = sconcat
        $ condTreeData node :|
        [resolve plan flags t | (cond,t,_) <- condTreeComponents node
                                , isTrue cond]
  where
    isTrue (Var (Flag f))
        | Just x <- HM.lookup f flags = x
        | otherwise = error $ "Unknown flag: " ++ show f
    isTrue (Var (Impl GHC range)) = withinRange (ghcVersion plan) range
    isTrue (Var (Impl _ _)) = False
    isTrue (Var (OS os)) = os == buildOS
    isTrue (Var (Arch arch)) = arch == buildArch
    isTrue (Lit x) = x
    isTrue (CNot x) = isTrue x
    isTrue (COr x y) = isTrue x || isTrue y
    isTrue (CAnd x y) = isTrue x && isTrue y

buildFromDesc :: PlanName -> PackageDescription -> Action BuiltPackage
buildFromDesc plan desc = case fmap libBuildInfo $ library desc of
    Just lib
        | buildable lib -> do
            let deps = [n | Dependency n _ <- targetBuildDepends
                                                lib]
            builtDeps <- askBuiltPackages plan deps
            putNormal $ "Building " ++ packageIdString (package desc)
            buildLibrary builtDeps desc
    _ -> error "buildFromDesc: no library"

buildLibrary :: [BuiltPackage] -> PackageDescription -> Action BuiltPackage
buildLibrary deps desc = do
    return BuiltPackage
                { builtTransitiveDBs = HS.empty
                , builtPackageName = packageName $ package desc
                }

{-
packageDbRule :: BuildPlan -> Rule ()
packageDbRule = "build/*/*/pkgdb/package.conf" #> \f [

libraries :: BuildPlan -> Rule ()
libraries
-}
