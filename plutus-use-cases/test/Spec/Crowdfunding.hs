{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TypeApplications    #-}

{-# OPTIONS_GHC -fno-warn-incomplete-uni-patterns -fno-warn-unused-do-bind #-}

module Spec.Crowdfunding(tests) where

import qualified Control.Foldl                         as L
import           Control.Lens                          ((&), (.~))
import           Control.Monad                         (void)
import           Control.Monad.Freer                   (run)
import           Control.Monad.Freer.Extras.Log        (LogLevel (..))
import           Data.ByteString.Lazy                  (ByteString)
import qualified Data.ByteString.Lazy                  as BSL
import           Data.Default                          (Default (..))
import qualified Data.Text.Encoding                    as T
import           Data.Text.Prettyprint.Doc             (Pretty (..), defaultLayoutOptions, layoutPretty, vsep)
import           Data.Text.Prettyprint.Doc.Render.Text (renderStrict)
import           Test.Tasty
import           Test.Tasty.Golden                     (goldenVsString)
import qualified Test.Tasty.HUnit                      as HUnit

import qualified Ledger.Ada                            as Ada
import           Ledger.Slot                           (Slot (..))
import           Ledger.Time                           (POSIXTime)
import qualified Ledger.TimeSlot                       as TimeSlot
import           Plutus.Contract                       hiding (runError)
import           Plutus.Contract.Test
import           Plutus.Contracts.Crowdfunding
import           Plutus.Trace.Emulator                 (ContractHandle (..), EmulatorTrace)
import qualified Plutus.Trace.Emulator                 as Trace
import qualified PlutusTx
import qualified PlutusTx.Prelude                      as PlutusTx
import qualified Streaming.Prelude                     as S
import qualified Wallet.Emulator.Folds                 as Folds
import           Wallet.Emulator.Stream                (filterLogLevel, foldEmulatorStreamM)

theContract :: POSIXTime -> Contract () CrowdfundingSchema ContractError ()
theContract startTime = crowdfunding $ theCampaign startTime

tests :: TestTree
tests = testGroup "crowdfunding"
    [ checkPredicate "Expose 'contribute' and 'scheduleCollection' endpoints"
        (endpointAvailable @"contribute" (theContract startTime) (Trace.walletInstanceTag w1)
        .&&. endpointAvailable @"schedule collection" (theContract startTime) (Trace.walletInstanceTag w1)
        )
        $ do
            slotCfg <- Trace.getSlotConfig
            void (Trace.activateContractWallet w1 $ theContract $ TimeSlot.scSlotZeroTime slotCfg)

    , checkPredicateOptions (defaultCheckOptions & maxSlot .~ 20) "make contribution"
        (walletFundsChange w1 (Ada.lovelaceValueOf (-100)))
        $ let contribution = Ada.lovelaceValueOf 100
          in makeContribution w1 contribution >> void Trace.nextSlot

    , checkPredicate "make contributions and collect"
        (walletFundsChange w1 (Ada.lovelaceValueOf 225))
        successfulCampaign

    , checkPredicate "cannot collect money too late"
        (walletFundsChange w1 PlutusTx.zero
        .&&. assertNoFailedTransactions)
        $ do
            ContractHandle{chInstanceId} <- startCampaign
            makeContribution w2 (Ada.lovelaceValueOf 100)
            makeContribution w3 (Ada.lovelaceValueOf 100)
            makeContribution w4 (Ada.lovelaceValueOf 25)
            Trace.freezeContractInstance chInstanceId
            -- Add some blocks to bring the total up to 31
            -- (that is, above the collection deadline)
            void $ Trace.waitUntilSlot (Slot 31)
            -- Then inform the wallet. It's too late to collect the funds
            -- now.
            Trace.thawContractInstance chInstanceId

    , checkPredicate "cannot collect unless notified"
        (walletFundsChange w1 PlutusTx.zero)
        $ do
            ContractHandle{chInstanceId} <- startCampaign
            makeContribution w2 (Ada.lovelaceValueOf 100)
            makeContribution w3 (Ada.lovelaceValueOf 100)
            makeContribution w4 (Ada.lovelaceValueOf 25)
            Trace.freezeContractInstance chInstanceId
            -- The contributions could be collected now, but without
            -- the slot notifications, wallet 1 is not aware that the
            -- time has come, so it does not submit the transaction.
            void $ Trace.waitUntilSlot 35

    , checkPredicate "can claim a refund"
        (walletFundsChange w1 mempty
        .&&. walletFundsChange w2 mempty
        .&&. walletFundsChange w3 mempty)
        $ do
            ContractHandle{chInstanceId} <- startCampaign
            makeContribution w2 (Ada.lovelaceValueOf 50)
            void $ makeContribution w3 (Ada.lovelaceValueOf 50)
            Trace.freezeContractInstance chInstanceId
            void $ Trace.waitUntilSlot 31

    , goldenPir "test/Spec/crowdfunding.pir" $$(PlutusTx.compile [|| mkValidator ||])
    ,   let
            deadline = 10000
            collectionDeadline = 15000
            owner = w1
            cmp = mkCampaign deadline collectionDeadline owner
        in HUnit.testCaseSteps "script size is reasonable" $ \step -> reasonable' step (contributionScript cmp) 30000

    , goldenVsString
        "renders the log of a single contract instance sensibly"
        "test/Spec/crowdfundingWallet1TestOutput.txt"
        (pure $ renderWalletLog successfulCampaign)

    , goldenVsString
        "renders the emulator log sensibly"
        "test/Spec/crowdfundingEmulatorTestOutput.txt"
        (pure $ renderEmulatorLog successfulCampaign)

    , let con :: Contract () EmptySchema ContractError () = throwError "something went wrong" in
        goldenVsString
        "renders an error sensibly"
        "test/Spec/contractError.txt"
        (pure $ renderWalletLog (void $ Trace.activateContractWallet w1 con))
    ]

    where
        startTime = TimeSlot.scSlotZeroTime def

renderWalletLog :: EmulatorTrace () -> ByteString
renderWalletLog trace =
    let result =
            run
            $ foldEmulatorStreamM (L.generalize $ Folds.instanceLog (Trace.walletInstanceTag w1))
            $ filterLogLevel Info
            $ Trace.runEmulatorStream def trace
    in BSL.fromStrict $ T.encodeUtf8 $ renderStrict $ layoutPretty defaultLayoutOptions $ vsep $ fmap pretty $ S.fst' result

renderEmulatorLog :: EmulatorTrace () -> ByteString
renderEmulatorLog trace =
    let result =
            run
            $ foldEmulatorStreamM (L.generalize Folds.emulatorLog)
            $ filterLogLevel Info
            $ Trace.runEmulatorStream def trace
    in BSL.fromStrict $ T.encodeUtf8 $ renderStrict $ layoutPretty defaultLayoutOptions $ vsep $ fmap pretty $ S.fst' result
