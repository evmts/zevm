// Intentionally minimal.
//
// The docs workflow runner sets up the Smithers dependency bridge and MDX
// plugin explicitly before importing the workflow entrypoint. Keeping preload
// empty avoids eager resolution against missing external packages.
