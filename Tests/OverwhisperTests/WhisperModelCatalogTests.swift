import XCTest
import WhisperKit
@testable import Overwhisper

final class WhisperModelCatalogTests: XCTestCase {

    // MARK: - Variant name canonicalization

    func testLegacyShortNamesExpandToFullVariants() {
        XCTAssertEqual(WhisperModel(rawValue: "small.en").variantName, "openai_whisper-small.en")
        XCTAssertEqual(WhisperModel(rawValue: "large-v3").variantName, "openai_whisper-large-v3")
        XCTAssertEqual(WhisperModel(rawValue: "large-v3_turbo").variantName, "openai_whisper-large-v3_turbo")
    }

    func testFullVariantNamesArePreserved() {
        let variants = [
            "openai_whisper-large-v3-v20240930_626MB",
            "distil-whisper_distil-large-v3",
            "distil-whisper_distil-large-v3_turbo_600MB"
        ]
        for variant in variants {
            XCTAssertEqual(WhisperModel(rawValue: variant).variantName, variant)
        }
    }

    func testShortNameStripsPublisherPrefix() {
        XCTAssertEqual(WhisperModel(rawValue: "openai_whisper-small.en").shortName, "small.en")
        XCTAssertEqual(WhisperModel(rawValue: "distil-whisper_distil-large-v3").shortName, "distil-large-v3")
        XCTAssertEqual(WhisperModel(rawValue: "tiny").shortName, "tiny")
    }

    /// A legacy stored preference and its expanded form must be treated as the same download.
    func testLegacyAndFullFormsResolveToSameVariant() {
        XCTAssertEqual(
            WhisperModel(rawValue: "small.en").variantName,
            WhisperModel(rawValue: "openai_whisper-small.en").variantName
        )
    }

    // MARK: - Derived attributes

    func testEnglishOnlyDetection() {
        XCTAssertTrue(WhisperModel(rawValue: "small.en").isEnglishOnly)
        XCTAssertTrue(WhisperModel(rawValue: "openai_whisper-tiny.en").isEnglishOnly)
        // distil-whisper large-v3 is an English-only distillation despite lacking an `.en` suffix.
        XCTAssertTrue(WhisperModel(rawValue: "distil-whisper_distil-large-v3").isEnglishOnly)
        XCTAssertFalse(WhisperModel(rawValue: "large-v3").isEnglishOnly)
        XCTAssertFalse(WhisperModel(rawValue: "openai_whisper-large-v3-v20240930").isEnglishOnly)
    }

    func testQuantizationParsing() {
        XCTAssertEqual(WhisperModel(rawValue: "openai_whisper-large-v3_947MB").quantizationSuffix, "947MB")
        XCTAssertEqual(WhisperModel(rawValue: "openai_whisper-large-v3-v20240930_626MB").quantizationSuffix, "626MB")
        XCTAssertNil(WhisperModel(rawValue: "openai_whisper-large-v3").quantizationSuffix)
        // `_turbo` is a compute variant, not a quantization level.
        XCTAssertNil(WhisperModel(rawValue: "openai_whisper-large-v3_turbo").quantizationSuffix)
    }

    func testTurboDetection() {
        XCTAssertTrue(WhisperModel(rawValue: "openai_whisper-large-v2_turbo_955MB").isTurbo)
        XCTAssertFalse(WhisperModel(rawValue: "openai_whisper-large-v2_949MB").isTurbo)
    }

    func testFamilyClassification() {
        XCTAssertEqual(WhisperModel(rawValue: "tiny.en").family, .tiny)
        XCTAssertEqual(WhisperModel(rawValue: "openai_whisper-small").family, .small)
        XCTAssertEqual(WhisperModel(rawValue: "openai_whisper-large-v2_949MB").family, .largeV2)
        XCTAssertEqual(WhisperModel(rawValue: "openai_whisper-large-v3_947MB").family, .largeV3)
        XCTAssertEqual(WhisperModel(rawValue: "distil-whisper_distil-large-v3_594MB").family, .distilLargeV3)
        // The dated build is a distinct family from plain large-v3 and must not collapse into it.
        XCTAssertEqual(WhisperModel(rawValue: "openai_whisper-large-v3-v20240930").family, .largeV3Turbo)
    }

    func testQuantizedModelReportsPublishedSize() {
        XCTAssertEqual(WhisperModel(rawValue: "openai_whisper-large-v3-v20240930_626MB").size, "~626MB")
        XCTAssertEqual(WhisperModel(rawValue: "openai_whisper-large-v3").size, "~3 GB")
    }

    func testDisplayNamesAreDistinctPerVariant() {
        let names = WhisperModel.knownRemoteModels.map(\.displayName)
        XCTAssertEqual(
            Set(names).count, names.count,
            "Every published variant needs a distinct label, otherwise the picker shows duplicates"
        )
    }

    // MARK: - Folder matching

    /// Regression test: the previous implementation matched on a collapsed base name, so
    /// selecting `large-v3` also claimed (and could delete) `large-v3_947MB` and
    /// `large-v3-v20240930`.
    func testFolderMatchingIsExactAcrossSimilarVariants() {
        XCTAssertTrue(ModelManager.folderName("openai_whisper-large-v3", matches: "large-v3"))
        XCTAssertTrue(ModelManager.folderName("openai_whisper-large-v3", matches: "openai_whisper-large-v3"))

        XCTAssertFalse(ModelManager.folderName("openai_whisper-large-v3_947MB", matches: "large-v3"))
        XCTAssertFalse(ModelManager.folderName("openai_whisper-large-v3-v20240930", matches: "large-v3"))
        XCTAssertFalse(ModelManager.folderName("openai_whisper-large-v3_turbo", matches: "large-v3"))
    }

    func testDistilFolderMatching() {
        XCTAssertTrue(ModelManager.folderName(
            "distil-whisper_distil-large-v3",
            matches: "distil-whisper_distil-large-v3"
        ))
        XCTAssertFalse(ModelManager.folderName(
            "distil-whisper_distil-large-v3_594MB",
            matches: "distil-whisper_distil-large-v3"
        ))
    }

    func testVariantFolderRecognition() {
        XCTAssertTrue(ModelManager.isModelVariantFolder("openai_whisper-base.en"))
        XCTAssertTrue(ModelManager.isModelVariantFolder("distil-whisper_distil-large-v3"))
        XCTAssertFalse(ModelManager.isModelVariantFolder(".cache"))
        XCTAssertFalse(ModelManager.isModelVariantFolder("parakeet-tdt-0.6b-v3"))
    }

    // MARK: - Catalog

    /// The offline list is device-tiered, so its exact contents vary by hardware. What must hold
    /// everywhere is that it is non-empty, well-formed, and free of duplicates.
    func testOfflineFallbackIsWellFormedForThisDevice() {
        let fallback = WhisperModel.knownRemoteModels
        XCTAssertFalse(fallback.isEmpty, "Offline users must still get a usable model list")

        for model in fallback {
            XCTAssertTrue(
                model.isPlausibleVariant,
                "\(model.rawValue) is not a recognizable variant id"
            )
        }

        let variants = fallback.map(\.variantName)
        XCTAssertEqual(Set(variants).count, variants.count, "Offline list must not repeat a variant")
    }

    /// Regression: the offline list was hard-coded to the Apple Silicon tier, which over-offered
    /// on older hardware — the M1 tier excludes the `_turbo` and `large-v3-v20240930` builds, and
    /// selecting one there fails at Core ML initialization. It must come from the device tier.
    func testOfflineFallbackIsDeviceTieredNotHardCoded() {
        let fallback = Set(WhisperModel.knownRemoteModels.map(\.variantName))
        let deviceTier = Set(WhisperKit.recommendedModels().supported)
        XCTAssertEqual(
            fallback, deviceTier,
            "Offline list must match WhisperKit's support tier for this device"
        )
    }

    // MARK: - Identity

    /// Regression: identity keyed on `rawValue` made a legacy preference ("small.en") compare
    /// unequal to its fully-qualified twin ("openai_whisper-small.en"), so Settings rendered the
    /// same model twice — once from the catalog, once appended as the "missing" selection.
    func testLegacyAndQualifiedIdsAreTheSameModel() {
        let legacy = WhisperModel(rawValue: "small.en")
        let qualified = WhisperModel(rawValue: "openai_whisper-small.en")

        XCTAssertEqual(legacy, qualified)
        XCTAssertEqual(legacy.hashValue, qualified.hashValue)
        XCTAssertEqual(legacy.id, qualified.id)
        XCTAssertEqual(Set([legacy, qualified]).count, 1)
    }

    func testCatalogContainmentMatchesLegacySelection() {
        let catalog = [
            WhisperModel(rawValue: "openai_whisper-small.en"),
            WhisperModel(rawValue: "openai_whisper-tiny.en")
        ]
        // The exact condition Settings uses to decide whether to append the selected model.
        XCTAssertTrue(
            catalog.contains(WhisperModel(rawValue: "small.en")),
            "A legacy selection must be recognized as already present, or it renders twice"
        )
    }

    func testDistinctVariantsRemainDistinct() {
        let a = WhisperModel(rawValue: "openai_whisper-large-v3")
        let b = WhisperModel(rawValue: "openai_whisper-large-v3_947MB")
        let c = WhisperModel(rawValue: "openai_whisper-large-v3-v20240930")
        XCTAssertEqual(Set([a, b, c]).count, 3)
    }

    // MARK: - Stored preference validation

    /// Regression: any string was accepted as a model id, so a corrupted or withdrawn value
    /// persisted forever — init fails, nothing resets it, and transcription throws
    /// `notInitialized` on every attempt.
    func testMalformedStoredIdsAreRejected() {
        XCTAssertFalse(WhisperModel(rawValue: "").isPlausibleVariant)
        XCTAssertFalse(WhisperModel(rawValue: "not-a-model").isPlausibleVariant)
        XCTAssertFalse(WhisperModel(rawValue: "parakeet-tdt-0.6b-v3").isPlausibleVariant)
    }

    func testValidStoredIdsAreAccepted() {
        XCTAssertTrue(WhisperModel(rawValue: "small.en").isPlausibleVariant, "legacy short name")
        XCTAssertTrue(WhisperModel(rawValue: "large-v3_turbo").isPlausibleVariant, "legacy short name")
        XCTAssertTrue(WhisperModel(rawValue: "openai_whisper-small.en").isPlausibleVariant)
        XCTAssertTrue(WhisperModel(rawValue: "distil-whisper_distil-large-v3").isPlausibleVariant)
        // A variant published after this build ships must still be accepted.
        XCTAssertTrue(WhisperModel(rawValue: "openai_whisper-large-v9_future").isPlausibleVariant)
    }

    func testSortingGroupsFamiliesAndOrdersQuantizedAfterFull() {
        let sorted = whisperModelsSorted([
            WhisperModel(rawValue: "openai_whisper-large-v3_947MB"),
            WhisperModel(rawValue: "openai_whisper-tiny"),
            WhisperModel(rawValue: "openai_whisper-large-v3"),
            WhisperModel(rawValue: "openai_whisper-base")
        ]).map(\.rawValue)

        XCTAssertEqual(sorted, [
            "openai_whisper-tiny",
            "openai_whisper-base",
            "openai_whisper-large-v3",
            "openai_whisper-large-v3_947MB"
        ])
    }
}
