{-# LANGUAGE DeriveAnyClass #-}
{-# OPTIONS_GHC -Wno-orphans #-}
module Development.Stake.Build
    ( buildPackageRules
    , askBuiltPackages
    )
    where

import Control.Applicative (liftA2, (<|>))
import Control.Monad (filterM, guard, msum)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Maybe
import Data.List (nub)
import Data.Maybe (catMaybes, fromMaybe)
import Data.Semigroup
import GHC.Generics hiding (packageName)
import Development.Shake
import Development.Shake.Classes
import Development.Shake.FilePath
import Development.Stake.Command
import Development.Stake.Config
import Development.Stake.Core
import Development.Stake.Package
import Development.Stake.Stackage
import Development.Stake.Persistent
import Distribution.ModuleName
import Distribution.Package
import Distribution.PackageDescription
import qualified Distribution.InstalledPackageInfo as IP
import Distribution.Text
import Distribution.System (buildOS, OS(..))
import Distribution.Version (Version(..))
import Distribution.Compiler
import qualified Data.Set as Set
import Data.Set (Set)
import Language.Haskell.Extension

buildPackageRules :: Rules ()
buildPackageRules = do
    addPersistent buildPackage

data BuiltPackageR = BuiltPackageR StackYaml PackageName
    deriving (Show,Typeable,Eq,Generic)
instance Hashable BuiltPackageR
instance Binary BuiltPackageR
instance NFData BuiltPackageR
type instance RuleResult BuiltPackageR = BuiltPackage

data TransitiveDeps = TransitiveDeps
    { transitiveDBs :: Set Artifact
    , transitiveLibFiles :: Set Artifact
    , transitiveIncludeDirs :: Set Artifact
    } deriving (Show, Eq, Typeable, Generic, Hashable, Binary, NFData)
instance Semigroup TransitiveDeps

instance Monoid TransitiveDeps where
    mempty = TransitiveDeps Set.empty Set.empty Set.empty
    TransitiveDeps x y z `mappend` TransitiveDeps x' y' z'
        = TransitiveDeps (x <> x') (y <> y') (z <> z')


-- ghc --package-db .stake/...text-1234.pkg/db --package text-1234
data BuiltPackage = BuiltPackage
    { builtPackageId :: PackageIdentifier
    , builtPackageTrans :: TransitiveDeps
    }
    deriving (Show,Typeable,Eq,Hashable,Binary,NFData,Generic)

askBuiltPackages :: StackYaml -> [PackageName] -> Action [BuiltPackage]
askBuiltPackages yaml pkgs = do
    askPersistents $ map (BuiltPackageR yaml) pkgs

data BuiltDeps = BuiltDeps [PackageIdentifier] TransitiveDeps

askBuiltDeps
    :: StackYaml
    -> [PackageName]
    -> Action BuiltDeps
askBuiltDeps stackYaml pkgs = do
    deps <- askBuiltPackages stackYaml pkgs
    return $ BuiltDeps (dedup $ map builtPackageId deps)
                  (foldMap builtPackageTrans deps)
  where
    dedup = Set.toList . Set.fromList

buildPackage :: BuiltPackageR -> Action BuiltPackage
buildPackage (BuiltPackageR stackYaml pkg) = do
    rerunIfCleaned
    conf <- askConfig stackYaml
    let r = resolvePackage conf pkg
    buildResolved stackYaml conf r

buildResolved
    :: StackYaml -> Config -> Resolved -> Action BuiltPackage
buildResolved _ conf (Builtin p) = do
    let ghc = configGhc conf
    result <- runCommandStdout
                $ ghcPkgProg ghc
                    ["describe" , display p]

    info <- return $! case IP.parseInstalledPackageInfo result of
        IP.ParseFailed err -> error (show err)
        IP.ParseOk _ info -> info
    return $ BuiltPackage p
                TransitiveDeps
                    { transitiveDBs = Set.empty
                    , transitiveLibFiles = ghcArtifacts ghc
                    , transitiveIncludeDirs
                            = Set.fromList
                                    $ map (parseGlobalPackagePath ghc)
                                    $ IP.includeDirs info
                        }
buildResolved stackYaml conf (Hackage p) =
    getPackageSourceDir p >>= buildPackageInDir stackYaml conf

-- TODO: don't copy everything if the local package is configured?
buildResolved stackYaml conf (Local dir) =
    buildPackageInDir stackYaml conf dir

buildPackageInDir :: StackYaml -> Config -> Artifact -> Action BuiltPackage
buildPackageInDir stackYaml conf packageSourceDir = do
    (desc, dir') <- configurePackage (plan conf) packageSourceDir
    buildFromDesc stackYaml conf dir' desc

buildFromDesc
    :: StackYaml -> Config -> Artifact -> PackageDescription -> Action BuiltPackage
buildFromDesc stackYaml conf packageSourceDir desc
    | Just lib <- library desc
    , let lbi = libBuildInfo lib
    , buildable lbi = do
            let depNames = [n | Dependency n _ <- targetBuildDepends
                                                lbi]
            deps <- askBuiltDeps stackYaml depNames
            buildLibrary conf deps packageSourceDir desc lib
    | otherwise = error "buildFromDesc: no library"

buildLibrary
    :: Config
    -> BuiltDeps
    -> Artifact
    -> PackageDescription -> Library
    -> Action BuiltPackage
buildLibrary conf deps@(BuiltDeps _ transDeps) packageSourceDir desc lib = do
    let ghc = configGhc conf
    let pkgPrefixDir = display (packageName $ package desc)
    let lbi = libBuildInfo lib
    let hiDir = pkgPrefixDir </> "hi"
    let oDir = pkgPrefixDir </> "o"
    let libName = "HS" ++ display (packageName $ package desc)
    let libFile = pkgPrefixDir </> "lib" ++ libName ++ "-ghc"
                                ++ display (ghcVersion $ plan conf) <.> "a"
    let dynLibFile = pkgPrefixDir </> "lib" ++ libName
                        ++ "-ghc" ++ display (ghcVersion $ plan conf) <.> dynExt
    let shouldBuildLib = not $ null $ exposedModules lib
    let pkgDir = (packageSourceDir />)
    let modules = otherModules lbi ++ exposedModules lib
    let cIncludeDirs = transitiveIncludeDirs transDeps
                        <> Set.map pkgDir (Set.fromList $ ifNull ""
                                                $ includeDirs lbi)
    let cFiles = map pkgDir $ cSources lbi
    moduleFiles <- mapM (findModule ghc desc lbi cIncludeDirs
                            $ sourceDirArtifacts packageSourceDir lbi)
                        modules
    moduleBootFiles <- catMaybes <$> mapM findBootFile moduleFiles
    cIncludes <- collectCIncludes desc lbi pkgDir
    (maybeLib, libFiles)  <- if not shouldBuildLib
            then return (Nothing, Set.empty)
            else do
                (hiDir', oDir') <- runCommand
                    (liftA2 (,) (output hiDir) (output oDir))
                    $ message ("Building " ++ display (package desc))
                    <> inputList (moduleBootFiles ++ cIncludes)
                    <> ghcCommand ghc deps lbi packageSourceDir
                            [ "-this-unit-id", display $ package desc
                            , "-hidir", hiDir
                            , "-odir", oDir
                            , "-dynamic-too"
                            ]
                            (moduleFiles ++ cFiles)
                let objs = map (\m -> oDir' /> (toFilePath m <.> "o")) modules
                                -- TODO: this is pretty janky...
                                ++ map (\f -> replaceArtifactExtension
                                                    (oDir'/> relPath f) "o")
                                        cFiles
                let dynModuleObjs = map (\m -> oDir' /> (toFilePath m <.> "dyn_o")) modules
                libArchive <- runCommand (output libFile)
                                    $ inputList objs
                                    <> message ("Linking static lib for "
                                                    ++ display (package desc))
                                    <> prog "ar" ([arParams, libFile]
                                                    ++ map relPath objs)
                dynLib <- runCommand (output dynLibFile)
                            $ inputList cIncludes
                            <> message ("Linking dynamic lib for "
                                            ++ display (package desc))
                            <> ghcCommand ghc deps lbi packageSourceDir
                                ["-shared", "-dynamic", "-o", dynLibFile]
                                (dynModuleObjs ++ cFiles)
                return (Just (libName, lib), Set.fromList [libArchive, dynLib, hiDir'])
    pkgDb <- registerPackage ghc pkgPrefixDir (package desc) lbi maybeLib
                deps libFiles
    return $ BuiltPackage (package desc)
            $ transDeps <> TransitiveDeps
                { transitiveDBs = Set.singleton pkgDb
                , transitiveLibFiles = libFiles
                -- TODO:
                , transitiveIncludeDirs = Set.empty
                }

arParams :: String
arParams = case buildOS of
                OSX -> "-cqv"
                _ -> "-rcs"

ghcCommand
    :: InstalledGhc
    -> BuiltDeps
    -> BuildInfo
    -> Artifact
    -> [String]
    -> [Artifact]
    -> Command
ghcCommand ghc (BuiltDeps depPkgs transDeps) bi packageSourceDir
    extraArgs ghcInputs
        = ghcProg ghc (args ++ map relPath ghcInputs)
            <> inputs (transitiveDBs transDeps)
            <> inputs (transitiveLibFiles transDeps)
            <> inputList ghcInputs
  where
    pkgDir = (packageSourceDir />)
    extensions =
        display (fromMaybe Haskell98 $ defaultLanguage bi)
            : map display (defaultExtensions bi ++ oldExtensions bi)
    args =
        -- Rely on GHC for module ordering and hs-boot files:
        [ "--make"
        , "-v0"
        , "-fPIC"
        , "-i"
        ]
        -- Necessary for boot files:
        ++ map (("-i" ++) . relPath) (sourceDirArtifacts packageSourceDir bi)
        ++
        concat (map (\p -> ["-package-db", relPath p])
                $ Set.toList $ transitiveDBs transDeps)
        ++
        concat [["-package", display d] | d <- depPkgs]
        ++ map ("-I"++) (map (relPath . pkgDir) $ includeDirs bi)
        ++ map ("-X" ++) extensions
        ++ concat [opts | (GHC,opts) <- options bi]
        ++ map ("-optP" ++) (cppOptions bi)
        -- TODO: configurable
        ++ ["-O0"]
        -- TODO: enable warnings for local builds
        ++ ["-w"]
        ++ ["-optc" ++ opt | opt <- ccOptions bi]
        ++ ["-l" ++ libDep | libDep <- extraLibs bi]
        -- TODO: linker options too?
        ++ extraArgs

sourceDirArtifacts :: Artifact -> BuildInfo -> [Artifact]
sourceDirArtifacts packageSourceDir bi
    = map (packageSourceDir />) $ ifNull "" $ hsSourceDirs bi

registerPackage
    :: InstalledGhc
    -> String -- ^ output prefix dir
    -> PackageIdentifier
    -> BuildInfo
    -> Maybe ( String  -- Library name for linking
             , Library)
    -> BuiltDeps
    -> Set Artifact
    -> Action Artifact
registerPackage ghc outPrefix pkg bi maybeLib (BuiltDeps depPkgs transDeps)
    libFiles
    = do
    spec <- writeArtifact (outPrefix </> "spec") $ unlines $
        [ "name: " ++ display (packageName pkg)
        , "version: " ++ display (packageVersion pkg)
        , "id: " ++ display pkg
        , "key: " ++ display pkg
        , "extra-libraries: " ++ unwords (extraLibs bi)
        , "depends: " ++ unwords (map display depPkgs)
        ]
        ++ case maybeLib of
            Nothing -> []
            Just (libName, lib) ->
                     [ "hs-libraries: " ++ libName
                     , "library-dirs: ${pkgroot}"
                     , "import-dirs: ${pkgroot}/hi"
                     , "exposed-modules: " ++ unwords (map display $ exposedModules lib)
                     , "hidden-modules: " ++ unwords (map display $ otherModules bi)
                     ]
    let relPkgDb = outPrefix </> "db"
    runCommand (output relPkgDb)
        $ ghcPkgProg ghc ["init", relPkgDb]
            <> ghcPkgProg ghc
                    (["-v0"]
                    ++ [ "--package-db=" ++ relPath f
                       | f <-  Set.toList $ transitiveDBs transDeps
                       ]
                    ++ ["--package-db", relPkgDb, "register",
                               relPath spec])
            <> input spec
            <> inputs libFiles
            <> inputs (transitiveDBs transDeps)


dynExt :: String
dynExt = case buildOS of
        OSX -> "dylib"
        _ -> "so"

-- TODO: Organize the arguments to this function better.
findModule
    :: InstalledGhc
    -> PackageDescription
    -> BuildInfo
    -> Set Artifact -- ^ Transitive C include dirs
    -> [Artifact]             -- Source directory to check
    -> ModuleName
    -> Action Artifact
findModule ghc desc bi cIncludeDirs paths m = do
    found <- runMaybeT $ genPathsModule m (package desc) <|>
                msum (map (search ghc bi cIncludeDirs m) paths)
    case found of
        Nothing -> error $ "Missing module " ++ display m
                        ++ "; searched " ++ show paths
        Just f -> return f

genPathsModule
    :: ModuleName -> PackageIdentifier -> MaybeT Action Artifact
genPathsModule m pkg = do
    guard $ m == pathsModule
    lift $ writeArtifact ("paths" </> display m <.> "hs") $ unlines
       [ "{-# LANGUAGE CPP #-}"
        , "module " ++ display m ++ " (getDataFileName, getDataDir, version) where"
        , "import Data.Version (Version(..))"
        , "version :: Version"
        , "version = Version " ++ show (versionBranch
                                            $ pkgVersion pkg)
                                ++ ""
                        ++ " []" -- tags are deprecated
        -- TODO:
        , "getDataFileName :: FilePath -> IO FilePath"
        , "getDataFileName = error \"getDataFileName: TODO\""
        , "getDataDir :: IO FilePath"
        , "getDataDir = error \"getDataDir: TODO\""
        ]
  where
    pathsModule = fromString $ "Paths_" ++ map fixHyphen (display $ pkgName pkg)
    fixHyphen '-' = '_'
    fixHyphen c = c


search
    :: InstalledGhc
    -> BuildInfo
    -> Set Artifact -- ^ Transitive C include dirs
    -> ModuleName
    -> Artifact -- ^ Source directory to check
    -> MaybeT Action Artifact
search ghc bi cIncludeDirs m srcDir
    = genHsc2hs <|>
      genHappy "y" <|>
      genHappy "ly" <|>
      genAlex "x" <|>
      existing
  where
    genHappy ext = do
        let yFile = srcDir /> (toFilePath m <.> ext)
        exists yFile
        let relOutput = toFilePath m <.> "hs"
        lift . runCommand (output relOutput)
             $ prog "happy"
                     ["-o", relOutput, relPath yFile]
                <> input yFile

    genHsc2hs = do
        let hsc = srcDir /> (toFilePath m <.> "hsc")
        exists hsc
        let relOutput = toFilePath m <.> "hs"
        lift $ runCommand (output relOutput)
             $ prog "hsc2hs"
                      (["-o", relOutput
                       , relPath hsc
                       ]
                       -- TODO: CPP options?
                       ++ ["--cflag=" ++ f | f <- ccOptions bi]
                       ++ ["-I" ++ relPath f | f <- Set.toList cIncludeDirs]
                       ++ ["-D__GLASGOW_HASKELL__="
                             ++ cppVersion (ghcInstalledVersion ghc)])
                <> input hsc <> inputs cIncludeDirs

    genAlex ext = do
       let xFile = srcDir /> (toFilePath m <.> ext)
       exists xFile
       let relOutput = toFilePath m <.> "hs"
       lift . runCommand (output relOutput)
            $ prog "alex"
                     ["-o", relOutput, relPath xFile]
               <> input xFile

    existing = let f = srcDir /> (toFilePath m <.> "hs")
                 in exists f >> return f

ifNull :: a -> [a] -> [a]
ifNull x [] = [x]
ifNull _ xs = xs

-- Find the "hs-boot" file corresponding to a "hs" file.
findBootFile :: Artifact -> Action (Maybe Artifact)
findBootFile hs = do
    let hsBoot = replaceArtifactExtension hs "hs-boot"
    bootExists <- doesArtifactExist hsBoot
    return $ guard bootExists >> return hsBoot

collectCIncludes :: PackageDescription -> BuildInfo -> (FilePath -> Artifact) -> Action [Artifact]
collectCIncludes desc bi pkgDir = do
    includeInputs <- findIncludeInputs pkgDir bi
    extras <- fmap concat $ mapM (\f -> matchArtifactGlob (pkgDir "") f)
                            $ extraSrcFiles desc
    return $ includeInputs ++ extras

findIncludeInputs :: (FilePath -> Artifact) -> BuildInfo -> Action [Artifact]
findIncludeInputs pkgDir bi = filterM doesArtifactExist candidates
  where
    candidates = nub -- TODO: more efficient
                 [ pkgDir $ d </> f
                -- TODO: maybe just installIncludes shouldn't be prefixed
                -- with include dir?
                 | d <- "" : includeDirs bi
                 , f <- includes bi ++ installIncludes bi
                 ]

cppVersion :: Version -> String
cppVersion v = case versionBranch v of
    (v1:v2:_) -> show v1 ++ if v2 < 10 then '0':show v2 else show v2
    _ -> error $ "cppVersion: " ++ display v

exists :: Artifact -> MaybeT Action ()
exists f = lift (doesArtifactExist f) >>= guard
