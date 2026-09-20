//
//  SeededWatchRoute.swift
//  OpenHikesWatch
//
//  The trail a screenshot run walks.
//
//  ## Why a copy and not the GPX
//
//  `OpenHikes/SimulatedLocations/KoenigsseeRinnkendlsteig.gpx` is the route
//  every other fixture in this project uses, and it is the right line — it
//  sits on a real trail, so the basemap under it shows a path rather than a
//  green field. But it belongs to the *phone* target, and a watch app cannot
//  read the phone's bundle. Adding it to this target's resources would put a
//  50 KB file into every shipping watch build to serve a debug fixture.
//
//  So the line is decimated to every fourth point and written out here, which
//  is 128 of the file's 507 and well inside ``WatchTrailPackage/pointBudget``.
//  Decimating costs nothing that matters: the watch is handed a decimated
//  route in real life too — that is what the budget *is* — and 128 points
//  across 10.6 km is a point every 83 m, which on a 49 mm screen is finer
//  than the line is wide.
//
//  ## Why the points are text
//
//  Because `no_magic_numbers` is on, and it flags every element of a numeric
//  array literal whether or not the array is a named constant — so a table of
//  384 doubles is 384 lint errors, and this repository carries no rule
//  suppressions anywhere to answer them with. A table of numbers the linter
//  cannot object to is a table of numbers in a string, which is also the
//  format the regeneration command below already emits.
//
//  Regenerate with, from the repository root:
//
//  ```sh
//  grep -o '<trkpt lat="[0-9.]*" lon="[0-9.]*"><ele>[0-9.]*' \
//      OpenHikes/SimulatedLocations/KoenigsseeRinnkendlsteig.gpx \
//      | sed -E 's/.*lat="([0-9.]*)" lon="([0-9.]*)"><ele>([0-9.]*)/\1 \2 \3/' \
//      | awk 'NR==1 || NR%4==0 { print } END { print }' \
//      | awk '!seen[$0]++'
//  ```
//

#if DEBUG
import Foundation
import OpenHikesShared

/// Königssee → Kühroint → Rinnkendlsteig → St. Bartholomä, decimated.
enum SeededWatchRoute {
    /// The route's own figures, from the GPX's metadata rather than re-derived
    /// from the decimated line — which is the distinction
    /// ``WatchTrailPackage/totalDistanceMeters`` exists to make.
    static let totalDistanceMeters = 10_600.0
    static let elevationGainMeters = 912.0
    static let elevationLossMeters = 70.0

    /// The line, parsed once.
    ///
    /// A malformed row is dropped rather than defaulted: a fixture with a
    /// coordinate at (0, 0) in it draws a line from the Alps to the Gulf of
    /// Guinea, which is a great deal harder to recognise as a typo than a
    /// route one point shorter.
    static let points: [WatchTrailPoint] = table
        .split(separator: "\n")
        .compactMap { row in
            let field = row.split(separator: " ")
            guard field.count == 3,
                  let latitude = Double(field[0]),
                  let longitude = Double(field[1]),
                  let elevation = Double(field[2])
            else { return nil }
            return WatchTrailPoint(
                latitude: latitude,
                longitude: longitude,
                elevationMeters: elevation
            )
        }

    /// Latitude, longitude and elevation in metres, one point per line.
    private static let table = """
        47.599436 12.984916 585.8
        47.599156 12.984563 585.0
        47.598513 12.984232 584.6
        47.597172 12.983335 590.1
        47.595641 12.981949 609.6
        47.593851 12.980429 633.6
        47.593288 12.980436 644.3
        47.592902 12.979855 657.9
        47.592322 12.977911 679.9
        47.591369 12.976730 705.3
        47.590650 12.976468 724.1
        47.590766 12.975417 759.4
        47.590697 12.973538 804.9
        47.591002 12.973729 820.3
        47.591242 12.972782 825.0
        47.591126 12.972067 842.3
        47.591241 12.971519 861.3
        47.590879 12.971162 874.1
        47.588910 12.969275 903.9
        47.588158 12.968402 927.6
        47.587673 12.968999 951.9
        47.587663 12.970856 974.4
        47.587100 12.972403 994.1
        47.586571 12.974102 1027.4
        47.584712 12.975004 1067.6
        47.584061 12.974970 1093.4
        47.583112 12.974816 1115.9
        47.582765 12.975131 1130.9
        47.581976 12.974941 1148.6
        47.581541 12.973883 1171.7
        47.581734 12.972788 1189.7
        47.581277 12.972660 1202.0
        47.580930 12.972433 1222.3
        47.580260 12.972223 1244.3
        47.580317 12.971035 1258.1
        47.580269 12.969808 1279.3
        47.579619 12.970099 1286.1
        47.579642 12.970057 1285.2
        47.578895 12.969670 1307.7
        47.577733 12.967657 1329.4
        47.577003 12.967404 1354.4
        47.574550 12.967001 1391.9
        47.573342 12.967293 1414.0
        47.572887 12.966814 1424.3
        47.572987 12.965304 1424.0
        47.572621 12.964793 1423.7
        47.572246 12.964721 1424.9
        47.572256 12.964697 1425.5
        47.572256 12.964729 1424.9
        47.572268 12.964728 1425.3
        47.572261 12.964738 1425.4
        47.572258 12.964728 1425.1
        47.572236 12.964712 1425.8
        47.572268 12.964706 1425.5
        47.572240 12.964747 1426.0
        47.571921 12.964780 1424.6
        47.572094 12.964341 1419.3
        47.571803 12.963832 1415.9
        47.571763 12.962773 1412.9
        47.571383 12.961676 1409.4
        47.571258 12.961540 1408.1
        47.570939 12.961663 1407.1
        47.570242 12.961700 1412.0
        47.569807 12.962121 1420.7
        47.569284 12.962251 1421.1
        47.568498 12.962868 1417.7
        47.567495 12.964195 1404.3
        47.565738 12.965516 1380.9
        47.564837 12.965668 1363.7
        47.564507 12.965363 1354.4
        47.564013 12.965706 1349.3
        47.563599 12.965146 1342.3
        47.563659 12.964742 1332.9
        47.563642 12.964756 1332.7
        47.563650 12.964744 1332.7
        47.563609 12.964673 1329.6
        47.563829 12.964104 1319.7
        47.563793 12.963775 1311.6
        47.563548 12.963382 1302.3
        47.563109 12.963238 1290.6
        47.562645 12.963126 1273.1
        47.561978 12.962968 1259.6
        47.561495 12.962680 1246.6
        47.561104 12.962514 1240.9
        47.560642 12.962352 1251.1
        47.559791 12.962031 1243.3
        47.559515 12.962016 1234.3
        47.559452 12.961742 1241.0
        47.559046 12.961166 1258.1
        47.558634 12.961064 1239.9
        47.558226 12.959939 1235.3
        47.558070 12.960108 1237.4
        47.557243 12.959722 1192.6
        47.556746 12.959700 1149.7
        47.556381 12.959770 1126.3
        47.556202 12.959999 1100.0
        47.556146 12.960758 1068.4
        47.556384 12.961324 1048.0
        47.556567 12.961706 1030.0
        47.556827 12.962459 994.7
        47.557028 12.963382 954.1
        47.557005 12.963956 920.9
        47.557015 12.964298 896.6
        47.556675 12.964595 876.9
        47.556500 12.964854 853.7
        47.556059 12.965254 823.6
        47.555209 12.965239 795.6
        47.554879 12.965229 773.1
        47.554619 12.965610 742.6
        47.553495 12.964453 727.1
        47.552664 12.963910 711.4
        47.552247 12.964148 693.4
        47.551949 12.964355 684.1
        47.552083 12.964750 670.0
        47.552151 12.964967 659.4
        47.552025 12.965519 646.6
        47.551193 12.966065 630.6
        47.550041 12.966886 616.6
        47.549639 12.967660 612.9
        47.548614 12.969192 613.9
        47.548221 12.969650 613.1
        47.547184 12.970708 611.9
        47.546758 12.971201 611.0
        47.546351 12.971370 612.9
        47.546025 12.971377 611.1
        47.544754 12.972700 606.7
        47.544621 12.972410 607.1
        47.544020 12.972418 607.8
        """
}
#endif
