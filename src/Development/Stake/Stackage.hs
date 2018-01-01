{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE OverloadedStrings #-}
module Development.Stake.Stackage
    ( buildPlanRules
    , askBuildPlan
    , askInstalledGhc
    , installGhcRules
    , InstalledGhc(..)
    , ghcArtifacts
    , ghcProg
    , ghcPkgProg
    , hsc2hsProg
    , parseGlobalPackagePath
    , PlanName(..)
    , BuildPlan(..)
    ) where

import GHC.Generics
import Data.Binary.Orphans ()
import Data.Monoid ((<>))
import Control.Exception (throw)
import qualified Data.HashMap.Strict as HM
import qualified Data.List as List
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Yaml
import Distribution.Version
import Distribution.Package
import Distribution.System (buildPlatform, Platform(..), Arch(..), OS(..))
import qualified Distribution.Text as Cabal
import Development.Shake.Classes hiding (get)
import Development.Stake.Command
import Development.Stake.Download
import Development.Stake.Orphans ()
import Development.Stake.Persistent
import Development.Shake.FilePath
import Development.Shake

newtype PlanName = PlanName { renderPlanName :: String }
    deriving (Show,Typeable,Eq,Hashable,Binary,NFData,Generic)

instance FromJSON PlanName where
    parseJSON = fmap PlanName . parseJSON

data BuildPlan = BuildPlan
    { corePackageVersions :: HM.HashMap PackageName Version
    , packageVersions :: HM.HashMap PackageName Version
    , ghcVersion :: Version
    } deriving (Show,Typeable,Eq,Hashable,Binary,NFData,Generic)

instance FromJSON BuildPlan where
    parseJSON = withObject "Plan" $ \o -> do
        sys <- o .: "system-info"
        coreVersions <- sys .: "core-packages"
        ghcVers <- sys .: "ghc-version"
        pkgs <- o .: "packages"
        pkgVersions <- mapM (.: "version") pkgs
        return BuildPlan { corePackageVersions = coreVersions
                         , packageVersions = pkgVersions
                         , ghcVersion = ghcVers
        }

buildPlanRules :: Rules ()
buildPlanRules = addPersistent $ \(ReadPlan planName) -> do
        f <- askDownload Download
                { downloadFilePrefix = "stackage/plan"
                , downloadName = renderPlanName planName <.> "yaml"
                , downloadUrlPrefix = planUrlPrefix planName
                }
        cs <- readArtifactB f
        case decodeEither' cs of
            Left err -> throw err
            Right x -> return x

planUrlPrefix :: PlanName -> String
planUrlPrefix (PlanName name)
    | "lts-" `List.isPrefixOf` name = ltsBuildPlansUrl
    | "nightly-" `List.isPrefixOf` name = nightlyBuildPlansUrl
    | otherwise = error $ "Unrecognized plan name " ++ show name
  where
    ltsBuildPlansUrl = "https://raw.githubusercontent.com/fpco/lts-haskell/master/"
    nightlyBuildPlansUrl = "https://raw.githubusercontent.com/fpco/stackage-nightly/master/"

newtype ReadPlan = ReadPlan PlanName
    deriving (Show,Typeable,Eq,Hashable,Binary,NFData,Generic)
type instance RuleResult ReadPlan = BuildPlan

askBuildPlan :: PlanName -> Action BuildPlan
askBuildPlan = askPersistent . ReadPlan


newtype InstallGhc = InstallGhc Version
    deriving (Show, Typeable, Eq, Hashable, Binary, NFData, Generic)

-- | TODO: make the below functions that use Version take InstalledGhc directly instead
data InstalledGhc = InstalledGhc
    { ghcInstallDir :: Artifact
    , ghcInstalledVersion :: Version
    } deriving (Show, Typeable, Eq, Generic)
instance Hashable InstalledGhc
instance Binary InstalledGhc
instance NFData InstalledGhc

type instance RuleResult InstallGhc = InstalledGhc

globalPackageDb :: InstalledGhc -> Artifact
globalPackageDb ghc = ghcLibRoot ghc /> packageConfD

packageConfD :: String
packageConfD = "package.conf.d"

ghcArtifacts :: InstalledGhc -> Set.Set Artifact
ghcArtifacts g = Set.fromList [ghcInstallDir g, globalPackageDb g]

askInstalledGhc :: Version -> Action InstalledGhc
askInstalledGhc = askPersistent . InstallGhc

ghcLibRoot :: InstalledGhc -> Artifact
ghcLibRoot g = ghcLibRootA (ghcInstalledVersion g) (ghcInstallDir g)

ghcLibRootA :: Version -> Artifact -> Artifact
ghcLibRootA version installDir =
    installDir /> ("lib/ghc-" ++ Cabal.display version)

-- | Convert @${pkgroot}@ prefixes, for utilities like hsc2hs that don't
-- see packages directly
--
parseGlobalPackagePath :: InstalledGhc -> FilePath -> Artifact
parseGlobalPackagePath ghc f
    | Just f' <- List.stripPrefix "${pkgroot}/" f
        = ghcLibRoot ghc /> f'
    | otherwise = externalFile f

ghcBinDir :: InstalledGhc -> Artifact
ghcBinDir ghc = ghcLibRoot ghc /> "bin"

ghcProg :: InstalledGhc -> [String] -> Command
ghcProg ghc args =
    progA (ghcBinDir ghc /> "ghc")
        (["-B" ++ pathIn (ghcLibRoot ghc)
         , "-clear-package-db"
         , "-hide-all-packages"
         , "-package-db=" ++ pathIn (globalPackageDb ghc)
         ] ++ args)
        <> input (ghcLibRoot ghc)
        <> input (globalPackageDb ghc)

ghcPkgProg :: InstalledGhc -> [String] -> Command
ghcPkgProg ghc args =
    progA (ghcBinDir ghc /> "ghc-pkg")
        ([ "--global-package-db=" ++ pathIn (globalPackageDb ghc)
         , "--no-user-package-db"
         , "--no-user-package-conf"
         ] ++ args)
        <> input (ghcLibRoot ghc)
        <> input (globalPackageDb ghc)

hsc2hsProg :: InstalledGhc -> [String] -> Command
hsc2hsProg ghc args =
    progA (ghcBinDir ghc /> "hsc2hs")
        (("--template=${TMPDIR}/" ++ pathIn template) : args)
    <> input template
  where
    template = ghcLibRoot ghc /> "template-hsc.h"

installGhcRules :: Rules ()
installGhcRules = addPersistent $ \(InstallGhc version) -> do
    setupYaml <- askDownload Download
                    { downloadFilePrefix = "stackage/setup"
                    , downloadName = "stack-setup-2.yaml"
                    , downloadUrlPrefix = setupUrl
                    }
    -- TODO: don't re-parse the yaml for every GHC version
    cs <- readArtifactB setupYaml
    case decodeEither' cs of
        Left err -> throw err
        Right x
            | Just download <- HM.lookup version (ghcVersions x)
                -> downloadAndInstallGHC version download
            | otherwise -> error $ "Couldn't find GHC version" ++ Cabal.display version
  where
    setupUrl = "https://raw.githubusercontent.com/fpco/stackage-content/master/stack"


data DownloadInfo = DownloadInfo
    { downloadUrl :: String
    -- TODO: use these
    , _contentLength :: Int
    , _sha1 :: String
    }

instance FromJSON DownloadInfo where
    parseJSON = withObject "DownloadInfo" $ \o ->
        DownloadInfo <$> o .: "url"
                     <*> o .: "content-length"
                     <*> o .: "sha1"

-- TODO: multiple OSes, configure-env

newtype StackSetup = StackSetup { ghcVersions :: HM.HashMap Version DownloadInfo }

instance FromJSON StackSetup where
    parseJSON = withObject "StackSetup" $ \o -> do
        ghc <- o .: "ghc"
        StackSetup <$> (ghc .: platformKey)

-- TODO: make this more configurable (eventually, using
-- `LocalBuildInfo.hostPlatform` to help support cross-compilation)
platformKey :: Text
platformKey = case buildPlatform of
    Platform I386   Linux   -> "linux32"
    Platform X86_64 Linux   -> "linux64"
    Platform I386   OSX     -> "macosx"
    Platform X86_64 OSX     -> "macosx"
    Platform I386   FreeBSD -> "freebsd32"
    Platform X86_64 FreeBSD -> "freebsd64"
    Platform I386   OpenBSD -> "openbsd32"
    Platform X86_64 OpenBSD -> "openbsd64"
    Platform I386   Windows -> "windows32"
    Platform X86_64 Windows -> "windows64"
    Platform Arm    Linux   -> "linux-armv7"
    _ -> error $ "Unrecognized platform: " ++ Cabal.display buildPlatform


downloadAndInstallGHC :: Version -> DownloadInfo -> Action InstalledGhc
downloadAndInstallGHC version download = do
    -- TODO: reenable this once we've fixed the issue with nondetermistic
    -- temp file locations.
    -- rerunIfCleaned
    let (url, f) = splitFileName $ downloadUrl download
    tar <- askDownload Download
            { downloadFilePrefix = "stackage/ghc"
            , downloadName = f
            , downloadUrlPrefix = url
            }
    -- TODO: check file size and sha1
    -- GHC's configure step requires an absolute prefix.
    -- We'll install it explicitly in ${TMPDIR}, but that puts explicit references
    -- to those paths in the package DB.  So we'll then generate a new DB with
    -- relative paths.
    let installDir = "ghc-install"
    let unpackedDir = "ghc-" ++ Cabal.display version
    installed <- runCommand
       (output installDir)
       $ message "Unpacking GHC"
          <> prog "tar" ["-xJf", pathIn tar, "-C", pathOut ""]
          <> withCwd (pathOut unpackedDir)
                (message "Installing GHC locally"
                <> progTemp (unpackedDir </> "configure")
                        ["--prefix=${TMPDIR}/" ++ pathOut installDir]
                <> prog "make" ["install"])
    fixed <- makeRelativeGlobalDb
                    InstalledGhc { ghcInstallDir = installed
                                 , ghcInstalledVersion = version
                                 }
    runCommand_ $ ghcPkgProg fixed ["check"]
    return fixed

makeRelativeGlobalDb :: InstalledGhc -> Action InstalledGhc
makeRelativeGlobalDb ghc = do
    -- List all packages, excluding Cabal which stack doesn't consider a "core"
    -- package.
    -- TODO: if our package ids included a hash, this wouldn't be as big a problem
    -- because two versions of the same package could exist simultaneously.
    builtinPackages <- fmap (filter (/= "Cabal") . words) $ runCommandStdout
                        $ ghcPkgProg ghc
                            ["list", "--global", "--names-only",
                             "--simple-output" ]
    let makePkgConf pkg = do
            desc <- runCommandStdout
                        $ ghcPkgProg ghc ["describe", pkg]
            let tempRoot = parsePkgRoot desc
            let desc' =
                    T.unpack
                    . T.replace (T.pack tempRoot)
                        (T.pack "${pkgroot}")
                    . T.pack
                    $ desc
            writeArtifact (pkg ++ ".conf") desc'
    confs <- mapM makePkgConf builtinPackages
    -- let globalRelativePackageDb = "global-packages/package-fixed.conf.d"
    let ghcInstall = "ghc-fixed"
    let ghcLib = ghcInstall </> "lib"
                    </> ("ghc-" ++ Cabal.display (ghcInstalledVersion ghc))
    let db = pathOut (ghcLib </> packageConfD)
    let ghcPkg = progTemp (ghcLib </> "bin/ghc-pkg")
    ghcDir <- runCommand (output ghcInstall)
                $ shadow (ghcInstallDir ghc) ghcInstall
                <> inputList confs
                <> message "Making global DB relative"
                <> prog "rm" ["-rf", db]
                <> ghcPkg ["init", db]
                <> foldMap
                        (\conf -> ghcPkg
                            [ "register", pathIn conf
                            , "--global-package-db=" ++ db
                            , "--no-user-package-db"
                            , "--no-user-package-conf"
                            , "--no-expand-pkgroot"
                            , "--force"
                            ])
                        confs
    return ghc { ghcInstallDir = ghcDir }

-- TODO: this gets the TMPDIR that was used when installing; consider allowing
-- that to be captured explicitly.
parsePkgRoot :: String -> String
parsePkgRoot desc = loop $ lines desc
  where
    loop [] = error "Couldn't parse pkgRoot: " ++ show desc
    loop (l:ls)
        | take (length prefix) l == prefix = takeDirectory
                                            $ drop (length prefix) l
        | otherwise = loop ls
    prefix = "library-dirs: "
