import XCTest
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

    func testFallbackCatalogCoversAllPublishedVariants() {
        // The bundled list is what offline users see; it should span every family we know about.
        let families = Set(WhisperModel.knownRemoteModels.map(\.family))
        XCTAssertTrue(families.contains(.distilLargeV3))
        XCTAssertTrue(families.contains(.largeV3Turbo))
        XCTAssertTrue(families.contains(.tiny))
        XCTAssertGreaterThan(
            WhisperModel.knownRemoteModels.count, WhisperModel.legacyModels.count,
            "The dynamic catalog must offer more than the 11 hard-coded legacy models"
        )
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
