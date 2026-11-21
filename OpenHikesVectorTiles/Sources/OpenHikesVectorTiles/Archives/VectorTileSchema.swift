//
//  VectorTileSchema.swift
//  OpenHikesVectorTiles
//
//  Which layouts of its two archives this build's renderer reads. One figure
//  each for everything that has to agree with ``VectorTileRasterizer``: the
//  tile server's manifest (``VectorTileArchiveManifest``) and, in the app,
//  the list of downloadable countries, which are cut from those archives.
//
//  `Scripts/offline-countries.sh` compiles this file into its tool, beside
//  the PMTiles reader, so it imports nothing.
//

public enum VectorTileSchema {
    /// The generation of the Protomaps basemap's layers the renderer draws.
    /// An archive of another is not drawn, because its layers and kinds
    /// would be read as something they are not.
    public static let basemap = 4
    /// The newest layout of the extras' layers the renderer draws. It draws
    /// every earlier one too, which only lacks what later ones added.
    /// Extras an older build would draw wrong go up as the next generation.
    public static let extrasGeneration = 2
}
