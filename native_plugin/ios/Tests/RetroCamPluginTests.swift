import XCTest
@testable import retro_cam

class RetroCamPluginTests: XCTestCase {

    var plugin: RetroCamPlugin!

    override func setUp() {
        super.setUp()
        plugin = RetroCamPlugin()
    }

    override func tearDown() {
        plugin = nil
        super.tearDown()
    }

    func testPresetParsing() {
        let json: [String: Any] = [
            "id": "test_cam",
            "name": "Test Cam",
            "category": "ccd",
            "outputType": "photo",
            "baseModel": [
                "sensor": ["type": "ccd-2005"]
            ]
        ]
        
        let preset = Preset(dictionary: json)
        XCTAssertNotNil(preset)
        XCTAssertEqual(preset?.id, "test_cam")
        XCTAssertEqual(preset?.category, "ccd")
        
        let sensorType = preset?.baseModel["sensor"] as? [String: Any]
        XCTAssertEqual(sensorType?["type"] as? String, "ccd-2005")
    }
    
    func testCCDParamsInitialization() {
        let params = CCDParams()
        XCTAssertEqual(params.chromaticAberration, 0.0)
        XCTAssertEqual(params.colorTemperature, 6500.0)
        XCTAssertEqual(params.bloomIntensity, 0.0)
        XCTAssertEqual(params.grainIntensity, 0.0)
        XCTAssertEqual(params.vignetteIntensity, 0.0)
    }
}
