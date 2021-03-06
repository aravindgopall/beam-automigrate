module Main where

import Control.Exception (bracket)
import Control.Monad.IO.Class (liftIO)
import qualified Data.List as L
import qualified Data.Text.Lazy as TL
import Database.Beam.AutoMigrate
import Database.Beam.AutoMigrate.BenchUtil (cleanDatabase, tearDownDatabase)
import Database.Beam.AutoMigrate.Postgres (getSchema)
import Database.Beam.AutoMigrate.Schema.Gen
import Database.Beam.AutoMigrate.Validity
import qualified Database.PostgreSQL.Simple as Pg
import qualified Database.Postgres.Temp as Tmp
import qualified Test.Database.Beam.AutoMigrate.Arbitrary as Pretty
import Test.QuickCheck
import Test.QuickCheck.Monadic
import Test.Tasty
import Test.Tasty.QuickCheck as QC

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "Tests" [properties]

properties :: TestTree
properties =
  testGroup
    "Integration tests"
    [ -- We test that if we generate and apply a migration from a 'hsSchema', when we read the
      -- 'Schema' back from the DB, we should end up with the original 'hsSchema'.
      dbResource $ \getResource -> QC.testProperty "Migration roundtrip (empty DB)" $
        \hsSchema -> hsSchema /= noSchema ==> dbProperty getResource $ \dbConn -> liftIO $ do
          let mig = migrate dbConn hsSchema
          runMigrationUnsafe dbConn mig
          dbSchema <- getSchema dbConn
          pure $ hsSchema Pretty.=== dbSchema,
      -- We test that after a successful migration, calling 'diff' should yield no edits.
      dbResource $ \getResource -> QC.testProperty "Diffing after a migration yields no edits" $
        \hsSchema -> hsSchema /= noSchema ==> dbProperty getResource $ \dbConn -> liftIO $ do
          let mig = migrate dbConn hsSchema
          runMigrationUnsafe dbConn mig
          dbSchema <- getSchema dbConn
          pure $ diff hsSchema dbSchema === Right []
    ]

-- | Execute a monadic 'Property' while also cleaning up any database's data at the end.
dbProperty :: Testable prop => IO (Tmp.DB, Pg.Connection) -> (Pg.Connection -> PropertyM IO prop) -> Property
dbProperty getResource prop = withMaxSuccess 50 $
  monadicIO $ do
    (_, dbConn) <- liftIO getResource
    r <- prop dbConn
    liftIO $ cleanDatabase dbConn
    pure r

-- | Acquire a temporary database for each 'TestTree', and dispose it afterwards.
dbResource :: (IO (Tmp.DB, Pg.Connection) -> TestTree) -> TestTree
dbResource use = withResource acquire release use
  where
    acquire :: IO (Tmp.DB, Pg.Connection)
    acquire = do
      r <- Tmp.start
      case r of
        Left e -> fail ("dbResource startup failed: " ++ show e)
        Right tmpDb -> do
          conn <- Pg.connectPostgreSQL (Tmp.toConnectionString tmpDb)
          pure (tmpDb, conn)

    release :: (Tmp.DB, Pg.Connection) -> IO ()
    release (db, conn) = tearDownDatabase conn >> Tmp.stop db
