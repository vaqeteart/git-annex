{- higher-level inotify interface
 -
 - Copyright 2012 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

{-# LANGUAGE CPP #-}

module Utility.Inotify where

import Common hiding (isDirectory)
import Utility.ThreadLock

import System.INotify
import qualified System.Posix.Files as Files
import System.IO.Error
import Control.Exception (throw)

type Hook = Maybe (FilePath -> IO ())

{- Watches for changes to files in a directory, and all its subdirectories
 - that are not ignored, using inotify. This function returns after
 - its initial scan is complete, leaving a thread running. Callbacks are
 - made for different events.
 -
 - Inotify is weak at recursive directory watching; the whole directory
 - tree must be walked and watches set explicitly for each subdirectory.
 -
 - To notice newly created subdirectories, inotify is used, and
 - watches are registered for those directories. There is a race there;
 - things can be added to a directory before the watch gets registered.
 -
 - To close the inotify race, each time a new directory is found, it also 
 - recursively scans it, assuming all files in it were just added,
 - and registering each subdirectory.
 -
 - Note: Due to the race amelioration, multiple add events may occur
 - for the same file.
 - 
 - Note: Moving a file will cause events deleting it from its old location
 - and adding it to the new location. 
 - 
 - Note: Modification of files is not detected, and it's assumed that when
 - a file that was open for write is closed, it's finished being written
 - to, and can be added.
 -
 - Note: inotify has a limit to the number of watches allowed,
 - /proc/sys/fs/inotify/max_user_watches (default 8192).
 - So this will fail if there are too many subdirectories. The
 - toomany hook is called when this happens.
 -}
watchDir :: INotify -> FilePath -> (FilePath -> Bool) -> Hook -> Hook -> Hook -> Hook -> Hook -> IO ()
watchDir i dir ignored toomany add addsymlink del deldir
	| ignored dir = noop
	| otherwise = do
		lock <- newLock
		let handler event = withLock lock (void $ go event)
		void (addWatch i watchevents dir handler)
			`catchIO` failedaddwatch
		withLock lock $
			mapM_ walk =<< filter (not . dirCruft) <$>
				getDirectoryContents dir
	where
		recurse d = watchDir i d ignored toomany add addsymlink del deldir

		-- Select only inotify events required by the enabled
		-- hooks, but always include Create so new directories can
		-- be walked.
		watchevents = Create : addevents ++ delevents
		addevents
			| isJust add || isJust addsymlink = [MoveIn, CloseWrite]
			| otherwise = []
		delevents
			| isJust del || isJust deldir = [MoveOut, Delete]
			| otherwise = []

		walk f = unless (ignored f) $ do
			let fullf = indir f
			r <- catchMaybeIO $ getSymbolicLinkStatus fullf
			case r of
				Nothing -> return ()
				Just s
					| Files.isDirectory s -> recurse fullf
					| Files.isSymbolicLink s -> addsymlink <@> f
					| Files.isRegularFile s -> add <@> f
					| otherwise -> return ()

		-- Ignore creation events for regular files, which won't be
		-- done being written when initially created, but handle for
		-- directories and symlinks.
		go (Created { isDirectory = isd, filePath = f })
			| isd = recurse $ indir f
			| isJust addsymlink =
				whenM (filetype Files.isSymbolicLink f) $
					addsymlink <@> f
			| otherwise = noop
		-- Closing a file is assumed to mean it's done being written.
		go (Closed { isDirectory = False, maybeFilePath = Just f }) =
			whenM (filetype Files.isRegularFile f) $
				add <@> f
		-- When a file or directory is moved in, walk it to add new
		-- stuff.
		go (MovedIn { filePath = f }) = walk f
		go (MovedOut { isDirectory = isd, filePath = f })
			| isd = deldir <@> f
			| otherwise = del <@> f
		-- Verify that the deleted item really doesn't exist,
		-- since there can be spurious deletion events for items
		-- in a directory that has been moved out, but is still
		-- being watched.
		go (Deleted { isDirectory = isd, filePath = f })
			| isd = guarded $ deldir <@> f
			| otherwise = guarded $ del <@> f
			where
				guarded = unlessM (filetype (const True) f)
		go _ = noop

		Just a <@> f = unless (ignored f) $ a $ indir f
		Nothing <@> _ = noop

		indir f = dir </> f

		filetype t f = catchBoolIO $ t <$> getSymbolicLinkStatus (indir f)

		-- Inotify fails when there are too many watches with a
		-- disk full error.
		failedaddwatch e
			| isFullError e =
				case toomany of
					Nothing -> throw e
					Just hook -> hook dir
			| otherwise = throw e
