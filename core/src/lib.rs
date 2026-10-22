//! sharemask-core: the platform-independent part of sharemask.
//!
//! The macOS app keeps its own Swift `RegionResolver` today; this crate is the start of the
//! Windows/Linux port and is kept behaviour-identical (same test cases). A platform port supplies:
//!   * a frame source (Windows.Graphics.Capture / PipeWire),
//!   * a window list in z-order with bounds in points, layer, alpha, title,
//!   * a sink (virtual display on Windows via an IddCx driver; a headless output on Linux),
//! and calls [`resolve`] every frame to get the rectangles to redact.
//!
//! Coordinates: input rects are top-left-origin "points"; output rects are frame pixels. The
//! `flip_y` flag produces bottom-left-origin output for renderers that want it (Core Image).

pub mod presets;
pub mod resolver;

pub use presets::*;
pub use resolver::*;
