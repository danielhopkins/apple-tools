import CoreLocation
import XCTest

@testable import Geocoding

/// Everything here is offline. `NetworkGeocoder` is deliberately untested by
/// this suite: exercising it would make `swift test` depend on Apple's servers
/// and on the machine having a network, which no other suite in this repo does.
/// What is pinned here is the parsing and labelling that decides *where* a
/// reminder or an event ends up — the part that fails silently when wrong.

final class CoordinateParsingTests: XCTestCase {
  func testParsesAPlainPair() throws {
    let point = try XCTUnwrap(Coordinate.parse("39.959595,-105.174511"))
    XCTAssertEqual(point.latitude, 39.959595, accuracy: 0.000001)
    XCTAssertEqual(point.longitude, -105.174511, accuracy: 0.000001)
  }

  func testToleratesSpaceAfterTheComma() throws {
    let point = try XCTUnwrap(Coordinate.parse("39.96, -105.17"))
    XCTAssertEqual(point.latitude, 39.96, accuracy: 0.001)
  }

  /// 🛑 A swapped pair is the dangerous input. `-105.23,40.03` is a longitude
  /// in the latitude slot, and every digit is plausible — accepting it puts the
  /// reminder in the Southern Ocean and nothing looks wrong until it fails to
  /// fire. Latitude beyond ±90 is the one signal that catches it.
  func testRejectsOutOfRangeValues() {
    XCTAssertNil(Coordinate.parse("-105.23,40.03"), "longitude in the latitude slot")
    XCTAssertNil(Coordinate.parse("91,0"))
    XCTAssertNil(Coordinate.parse("0,181"))
  }

  func testRejectsThingsThatAreNotPairs() {
    XCTAssertNil(Coordinate.parse("costco"))
    XCTAssertNil(Coordinate.parse("Boulder, CO"))
    XCTAssertNil(Coordinate.parse("39.96"))
    XCTAssertNil(Coordinate.parse(""))
  }

  /// `looksLikeCoordinates` decides whether a bad value is reported as an
  /// out-of-range coordinate or searched for on Maps. "Boulder, CO" splits on a
  /// comma into two parts and must still go to Maps.
  func testLooksLikeCoordinatesOnlyWhenBothHalvesAreNumbers() {
    XCTAssertTrue(Coordinate.looksLikeCoordinates("39.96,-105.17"))
    XCTAssertTrue(Coordinate.looksLikeCoordinates("-105.23,40.03"), "in range is a separate check")
    XCTAssertFalse(Coordinate.looksLikeCoordinates("Boulder, CO"))
    XCTAssertFalse(Coordinate.looksLikeCoordinates("4800 Baseline Rd, Boulder"))
  }
}

final class LabelledCoordinateTests: XCTestCase {
  /// The composed pipeline depends on this: `apple maps geocode --json` emits
  /// `at`, and `--at` must read it back with the name intact. Without the
  /// label the reminder reads "39.96,-105.17", which is correct and useless.
  func testRoundTripsThroughTheAtForm() throws {
    let result = GeocodeResult(
      name: "Costco Wholesale", latitude: 39.959595, longitude: -105.174511,
      source: .visitedPlace)
    XCTAssertEqual(result.atForm, "Costco Wholesale@39.959595,-105.174511")

    let parsed = try XCTUnwrap(Coordinate.parseLabelled(result.atForm))
    XCTAssertEqual(parsed.label, "Costco Wholesale")
    XCTAssertEqual(parsed.coordinate.latitude, 39.959595, accuracy: 0.000001)
    XCTAssertEqual(parsed.coordinate.longitude, -105.174511, accuracy: 0.000001)
  }

  func testABarePairHasNoLabel() throws {
    let parsed = try XCTUnwrap(Coordinate.parseLabelled("39.96,-105.17"))
    XCTAssertNil(parsed.label)
  }

  /// ⚠️ Splitting on the *first* `@` breaks any place name containing one, and
  /// the failure is silent: the lookup goes somewhere else entirely.
  func testSplitsOnTheLastAtSign() throws {
    let parsed = try XCTUnwrap(Coordinate.parseLabelled("Bar@Home@39.96,-105.17"))
    XCTAssertEqual(parsed.label, "Bar@Home")
    XCTAssertEqual(parsed.coordinate.latitude, 39.96, accuracy: 0.001)
  }

  /// A name containing `@` with no coordinate after it is a search query, not a
  /// malformed coordinate. Treating it as the latter would refuse a legitimate
  /// place name instead of looking it up.
  func testANameWithAnAtSignIsNotACoordinate() {
    XCTAssertNil(Coordinate.parseLabelled("Bar@Home, Boulder"))
    XCTAssertFalse(Coordinate.looksLikeCoordinates("Bar@Home, Boulder"))
  }

  func testALabelledPairOutOfRangeIsRejected() {
    XCTAssertNil(Coordinate.parseLabelled("Somewhere@200,0"))
  }

  func testAnEmptyLabelIsDroppedRatherThanStored() throws {
    let parsed = try XCTUnwrap(Coordinate.parseLabelled("@39.96,-105.17"))
    XCTAssertNil(parsed.label, "an empty name must not become the location's title")
  }
}

final class GeocodeSourceTests: XCTestCase {
  /// The `network` field in JSON is what tells a caller whether the answer left
  /// the machine. It must come from the source rather than being guessed by a
  /// consumer that does not know every case.
  func testOnlyTheTwoAppleLookupsCountAsNetwork() {
    XCTAssertFalse(GeocodeSource.visitedPlace.isNetwork)
    XCTAssertFalse(GeocodeSource.guidePlace.isNetwork)
    XCTAssertFalse(GeocodeSource.coordinate.isNetwork)
    XCTAssertTrue(GeocodeSource.mapsSearch.isNetwork)
    XCTAssertTrue(GeocodeSource.addressLookup.isNetwork)
  }

  func testRawValuesAreStableForScripting() {
    XCTAssertEqual(GeocodeSource.visitedPlace.rawValue, "visited-place")
    XCTAssertEqual(GeocodeSource.guidePlace.rawValue, "guide-place")
    XCTAssertEqual(GeocodeSource.mapsSearch.rawValue, "maps-search")
    XCTAssertEqual(GeocodeSource.addressLookup.rawValue, "address-lookup")
    XCTAssertEqual(GeocodeSource.coordinate.rawValue, "coordinate")
  }
}
