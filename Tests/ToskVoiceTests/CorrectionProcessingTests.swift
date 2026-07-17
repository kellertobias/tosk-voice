@testable import ToskVoice
import XCTest

final class CorrectionProcessingTests: XCTestCase {
    func testRejectsPromptEchoFromCorrectionModel() {
        let echoedPrompt = """
        TRANSCRIPT:
        Does it?

        SPOKEN CORRECTION:
        No, it seems not to. Okay, what's the output now?
        """

        XCTAssertNil(CorrectionModelOutput.clean(echoedPrompt))
    }

    func testAcceptsCleanMergedModelOutput() {
        XCTAssertEqual(
            CorrectionModelOutput.clean("  No, it seems not to. What's the output now?  "),
            "No, it seems not to. What's the output now?"
        )
    }

    func testDetectsNaturalOnTheFlyCorrection() {
        XCTAssertTrue(CorrectionTrigger.shouldAskModelToEdit("Oh no, strike that."))
        XCTAssertTrue(CorrectionTrigger.shouldAskModelToEdit("Let me rephrase that."))
        XCTAssertTrue(CorrectionTrigger.shouldAskModelToEdit("The first version, scratch that, the second version."))
    }

    func testDoesNotTreatLiteralStrikeThatPhraseAsCorrection() {
        XCTAssertFalse(CorrectionTrigger.shouldAskModelToEdit("I want to strike that balance carefully."))
    }

    func testEveryUtteranceAfterTheFirstUsesLiveEditor() {
        XCTAssertFalse(LiveDraftRouting.shouldUseModel(
            hasStagedText: false,
            utterance: "Let's start a test."
        ))
        XCTAssertTrue(LiveDraftRouting.shouldUseModel(
            hasStagedText: true,
            utterance: "Please remove the last sentence and keep this one."
        ))
    }

    func testNaturalCorrectionCanInvokeEditorBeforeDraftExists() {
        XCTAssertTrue(LiveDraftRouting.shouldUseModel(
            hasStagedText: false,
            utterance: "Let's start a test. I am saying something. Strike that, remove the last sentence. I'm telling something."
        ))
    }

    /// Preferences saved by builds that still had profiles migrate: the
    /// selected profile seeds the flat settings.
    @MainActor
    func testLegacyProfileSnapshotSeedsFlatPreferences() throws {
        let suiteName = "CorrectionProcessingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let json = """
        {
          "profiles": [{
            "id": "28BDF2DA-3DA7-4B68-9EFD-AE37FC2A5961",
            "name": "Existing Profile",
            "speechMode": "automaticBilingual",
            "destination": "focusedField",
            "overlayPlacement": "topRight",
            "glossary": ["Apos"],
            "diarizationEnabled": true,
            "condensedOutputEnabled": true
          }],
          "selectedProfileID": "28BDF2DA-3DA7-4B68-9EFD-AE37FC2A5961",
          "launchAtLogin": false
        }
        """
        defaults.set(Data(json.utf8), forKey: "ToskVoice.Preferences.v1")

        let store = PreferencesStore(defaults: defaults)

        XCTAssertEqual(store.glossary, ["Apos"])
        XCTAssertEqual(store.overlayPlacement, .topRight)
        XCTAssertTrue(store.diarizationEnabled)
        XCTAssertTrue(store.spokenCorrectionsEnabled)
        XCTAssertTrue(store.condensedOutputEnabled)
        XCTAssertEqual(store.quickDictationModel, .whisperBilingual)
        XCTAssertEqual(store.editWithVoiceModel, .appleSpeech)
        XCTAssertEqual(store.ttsProvider, .builtInOnly)
    }
}
