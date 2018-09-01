module Pier.Core.Directory
    ( createParentIfMissing
    ) where

import Control.Monad.IO.Class
import Development.Shake.FilePath
import System.Directory

-- | Create recursively the parent of the given path, if it doesn't exist.
createParentIfMissing :: MonadIO m => FilePath -> m ()
createParentIfMissing
    = liftIO . createDirectoryIfMissing True . parentDirectory

-- | Get the parent of the given directory or file.
--
-- Examples:
--
-- parentDirectory "foo/bar"  == "foo"
-- parentDirectory "foo/bar/" == "foo"
parentDirectory :: FilePath -> FilePath
parentDirectory = takeDirectory . dropTrailingPathSeparator
