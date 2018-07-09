{-# LANGUAGE MultiWayIf #-}
module Main (main) where

import Control.Exception (bracket)
import Control.Monad (join, void)
import Data.IORef
import Data.List.Split (splitOn)
import Data.Maybe (fromMaybe)
import Data.Monoid (Last(..))
import Data.Semigroup (Semigroup, (<>))
import Development.Shake hiding (command)
import Development.Shake.FilePath ((</>), takeDirectory, splitFileName)
import Distribution.Package
import Distribution.Text (display, simpleParse)
import Options.Applicative hiding (action)
import System.Directory as Directory
import System.Environment

import qualified Data.HashMap.Strict as HM

import Pier.Build.Components
import Pier.Build.Config
import Pier.Build.Stackage
import Pier.Core.Artifact hiding (runCommand)
import Pier.Core.Download
import Pier.Core.Persistent
import Pier.Core.Run

data CommandOpt
    = Clean
    | CleanAll
    | Build [(PackageName, Target)]
    | Run Sandboxed (PackageName, Target) [String]
    | Test Sandboxed (PackageName, Target)
    | Which (PackageName, Target)

data Sandboxed = Sandbox | NoSandbox

parseSandboxed :: Parser Sandboxed
parseSandboxed =
    flag NoSandbox Sandbox
        $ long "sandbox"
        <> help "Run hermetically in a temporary folder"

data CommonOptions = CommonOptions
    { pierYaml :: Last FilePath
    , shakeFlags :: [String]
    , lastHandleTemps :: Last HandleTemps
    , lastDownloadLocation :: Last DownloadLocation
    }

instance Semigroup CommonOptions where
    CommonOptions y f ht dl <> CommonOptions y' f' ht' dl'
        = CommonOptions (y <> y') (f <> f') (ht <> ht') (dl <> dl')

handleTemps :: CommonOptions -> HandleTemps
handleTemps = fromMaybe RemoveTemps . getLast . lastHandleTemps

downloadLocation :: CommonOptions -> DownloadLocation
downloadLocation = fromMaybe DownloadToHome . getLast . lastDownloadLocation

-- | Parse command-independent options.
--
-- These are allowed both at the top level
-- (for example, "-V" in "pier -V build TARGETS") and within individual
-- commands ("pier build -V TARGETS").  However, we want them to only appear
-- in "pier --help", not "pier build --help".  Doing so is slightly
-- cumbersome with optparse-applicative.
parseCommonOptions :: Hidden -> Parser CommonOptions
parseCommonOptions h = CommonOptions <$> parsePierYaml <*> parseShakeFlags h
                                     <*> parseHandleTemps
                                     <*> parseDownloadLocation
  where
    parsePierYaml :: Parser (Last FilePath)
    parsePierYaml = fmap Last $ optional $ strOption
                        $ long "pier-yaml" <> metavar "YAML" <> hide h

    parseHandleTemps :: Parser (Last HandleTemps)
    parseHandleTemps =
        Last . Just <$>
            flag RemoveTemps KeepTemps
                (long "keep-temps"
                <> help "Don't remove temporary directories")

    parseDownloadLocation :: Parser (Last DownloadLocation)
    parseDownloadLocation =
        Last . Just <$>
            flag DownloadToHome DownloadLocal
                (long "download-local"
                <> help "Store downloads in the local _pier directory")

data Hidden = Hidden | Shown

hide :: Hidden -> Mod f a
hide Hidden = hidden <> internal
hide Shown = mempty

parseShakeFlags :: Hidden -> Parser [String]
parseShakeFlags h =
    mconcat <$> sequenceA [verbosity, many parallelism, many shakeArg]
  where
    shakeArg = strOption (long "shake-arg" <> metavar "SHAKEARG" <> hide h)

    parallelism =
        fmap ("--jobs=" ++) . strOption
            $ long "jobs"
                <> short 'j'
                <> help "Number of job/threads at once [default CPUs]"
                <> hide h

    verbosity =
        fmap combineFlags . many . flag' 'V'
            $ long "verbose"
                <> short 'V'
                <> help "Increase the verbosity level"
                <> hide h

    combineFlags [] = []
    combineFlags vs = ['-':vs]

parser :: ParserInfo (CommonOptions, CommandOpt)
parser = fmap (\(x,(y,z)) -> (x <> y, z))
            $ info (helper <*> liftA2 (,) (parseCommonOptions Shown)
                                    parseCommand)
            $ progDesc "Yet another Haskell build tool"

parseCommand :: Parser (CommonOptions, CommandOpt)
parseCommand = subparser $ mconcat
    [ make "clean" cleanCommand "Clean project"
    , make "clean-all" cleanAllCommand "Clean project & dependencies"
    , make "build" buildCommand "Build project"
    , make "run" runCommand "Run executable"
    , make "test" testCommand "Run test suites"
    , make "which" whichCommand "Build executable and print its location"
    ]
  where
    make name act desc =
        command name $ info (liftA2 (,) (parseCommonOptions Hidden)
                                        (helper <*> act))
                     $ progDesc desc

cleanCommand :: Parser CommandOpt
cleanCommand = pure Clean

cleanAllCommand :: Parser CommandOpt
cleanAllCommand = pure CleanAll

buildCommand :: Parser CommandOpt
buildCommand = Build <$> many parseTarget

runCommand :: Parser CommandOpt
runCommand = Run <$> parseSandboxed <*> parseTarget
                 <*> many (strArgument (metavar "ARGUMENT"))

testCommand :: Parser CommandOpt
testCommand = Test <$> parseSandboxed <*> parseTarget

whichCommand :: Parser CommandOpt
whichCommand = Which <$> parseTarget


findPierYamlFile :: Maybe FilePath -> IO FilePath
findPierYamlFile (Just f) = return f
findPierYamlFile Nothing = getCurrentDirectory >>= loop
  where
    loop dir = do
        let baseFile = "pier.yaml"
        let candidate = dir </> baseFile
        let parent = takeDirectory dir
        exists <- Directory.doesFileExist candidate
        if
            | exists -> return candidate
            | parent == dir ->
                error $ "Couldn't locate " ++ baseFile
                    ++ " from the current directory"
            | otherwise -> loop parent

runWithOptions
    :: IORef (IO ()) -- ^ Sink for what to do after the build
    -> HandleTemps
    -> CommandOpt
    -> Rules ()
runWithOptions _ _ Clean = cleaning True
runWithOptions _ _ CleanAll = do
    liftIO unfreezeArtifacts
    cleaning True
    cleanAll
runWithOptions _ _ (Build targets) = do
    cleaning False
    action $ do
        -- Build everything if the targets list is empty
        targets' <- if null targets
                        then map (,TargetAll) . HM.keys . localPackages
                                <$> askConfig
                        else pure targets
        -- Keep track of the number of targets.
        -- TODO: count transitive deps as well.
        let numTargets = length targets'
        successCount <- liftIO $ newIORef (0::Int)
        forP targets' $ \(p,t) -> do
                            buildTarget p t
                            k <- liftIO $ atomicModifyIORef' successCount
                                        $ \n -> let n' = n+1 in (n', n')
                            putLoud $ "Built " ++ showTarget p t
                                    ++ " (" ++ show k ++ "/" ++ show numTargets ++ ")"
runWithOptions next ht (Run sandbox (pkg, target) args) = do
    cleaning False
    action $ do
        exe <- buildExeTarget pkg target
        liftIO $ writeIORef next $ runExe ht sandbox exe args
runWithOptions next ht (Test sandbox (pkg, TargetAllTestSuites)) = do
    cleaning False
    action $ do
        suites <- askBuiltTestSuites pkg
        sequence_
            $ (\suite -> liftIO $ writeIORef next $ runTestSuite ht sandbox suite)
            <$> suites
runWithOptions next ht (Test sandbox (pkg, target)) = do
    cleaning False
    action $ do
        suite <- buildTestSuiteTarget pkg target
        liftIO $ writeIORef next $ runTestSuite ht sandbox suite
runWithOptions _ _ (Which (pkg, target)) = do
    cleaning False
    action $ do
        exe <- buildExeTarget pkg target
        -- TODO: nicer output format.
        putNormal $ pathIn (builtBinary exe)

runExe :: HandleTemps -> Sandboxed -> BuiltExecutable -> [String] -> IO ()
runExe ht sandbox exe args =
    case sandbox of
        Sandbox -> callArtifact ht (builtExeDataFiles exe)
                        (builtBinary exe) args
        NoSandbox -> cmd_ (WithStderr False)
                        (pathIn $ builtBinary exe) args

runTestSuite :: HandleTemps -> Sandboxed -> BuiltTestSuite -> IO ()
runTestSuite ht sandbox suite = do
    let noArgs :: [String] = []
    case sandbox of
        Sandbox -> callArtifact ht (builtTestSuiteDataFiles suite)
                        (builtTestSuiteBinary suite) noArgs
        NoSandbox -> cmd_ (WithStderr False)
                        (pathIn $ builtTestSuiteBinary suite) noArgs

buildExeTarget :: PackageName -> Target -> Action BuiltExecutable
buildExeTarget pkg target = do
    name <- case target of
                TargetExe name -> return name
                TargetAll -> return $ display pkg
                TargetAllExes -> return $ display pkg
                TargetLib -> error "command can't be used with a \"lib\" target"
                TargetAllTestSuites -> error "command can't be used with any \"test-suite\" targets"
                TargetTestSuite _ -> error "command can't be used with a \"test-suite\" target"
    askBuiltExecutable pkg name

buildTestSuiteTarget :: PackageName -> Target -> Action BuiltTestSuite
buildTestSuiteTarget pkg target = do
    name <- case target of
                TargetExe _ -> error "command can't be used with an \"exe\" target"
                TargetAll -> return $ display pkg
                TargetAllExes -> error "command can't be used with any \"exe\" targets"
                TargetLib -> error "command can't be used with a \"lib\" target"
                TargetAllTestSuites -> return ""
                TargetTestSuite name -> return name
    askBuiltTestSuite pkg name

main :: IO ()
main = do
    (commonOpts, cmdOpt) <- execParser parser
    -- A store for an optional action to run after building.
    -- It may be set by runWithOptions.  This lets `pier run` "break" out
    -- of the Rules/Action monads.
    next <- newIORef $ pure ()
    -- Run relative to the `pier.yaml` file.
    -- Afterwards, move explicitly back into the original directory in case
    -- this code is being interpreted by ghci.
    -- TODO (#69): don't rely on setCurrentDirectory; just use absolute paths
    -- everywhere in the code.
    (root, pierYamlFile)
        <- splitFileName <$> findPierYamlFile (getLast $ pierYaml commonOpts)
    let ht = handleTemps commonOpts
    bracket getCurrentDirectory setCurrentDirectory $ const $ do
        setCurrentDirectory root
        withArgs (shakeFlags commonOpts) $ runPier $ do
            buildPlanRules
            buildPackageRules
            artifactRules ht
            downloadRules $ downloadLocation commonOpts
            installGhcRules
            configRules pierYamlFile
            runWithOptions next ht cmdOpt
        join $ readIORef next

-- TODO: move into Build.hs
data Target
    = TargetAll
    | TargetLib
    | TargetAllExes
    | TargetExe String
    | TargetAllTestSuites
    | TargetTestSuite String
    deriving Show

showTarget :: PackageName -> Target -> String
showTarget pkg t = display pkg ++ case t of
                TargetAll -> ""
                TargetLib -> ":lib"
                TargetAllExes -> ":exe"
                TargetExe e -> ":exe:" ++ e
                TargetAllTestSuites -> ":test-suite"
                TargetTestSuite s -> ":test-suite:" ++ s

parseTarget :: Parser (PackageName, Target)
parseTarget = argument (eitherReader readTarget) (metavar "TARGET")
  where
    readTarget :: String -> Either String (PackageName, Target)
    readTarget s = case splitOn ":" s of
        [n] -> (, TargetAll) <$> readPackageName n
        [n, "lib"] -> (, TargetLib) <$> readPackageName n
        [n, "exe"] -> (, TargetAllExes) <$> readPackageName n
        [n, "exe", e] -> (, TargetExe e) <$> readPackageName n
        [n, "test-suite"] -> (, TargetAllTestSuites) <$> readPackageName n
        [n, "test-suite", e] -> (, TargetTestSuite e) <$> readPackageName n
        _ -> Left $ "Error parsing target " ++ show s
    readPackageName n = case simpleParse n of
        Just p -> return p
        Nothing -> Left $ "Error parsing package name " ++ show n

buildTarget :: PackageName -> Target -> Action ()
buildTarget n TargetAll = void $ askMaybeBuiltLibrary n >> askBuiltExecutables n
buildTarget n TargetLib = void $ askBuiltLibrary n
buildTarget n TargetAllExes = void $ askBuiltExecutables n
buildTarget n (TargetExe e) = void $ askBuiltExecutable n e
buildTarget n TargetAllTestSuites = void $ askBuiltTestSuites n
buildTarget n (TargetTestSuite s) = void $ askBuiltTestSuite n s
