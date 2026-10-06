//! Geometry and layer placement, mirroring the macOS LayerTransform record.
use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// How a layer's pixels are sampled when its transform scales them.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum Sampling {
    #[default]
    HighQuality,
    Smooth,
    Nearest,
}

impl Sampling {
    pub fn as_str(self) -> &'static str {
        match self {
            Sampling::HighQuality => "High quality",
            Sampling::Smooth => "Smooth",
            Sampling::Nearest => "Nearest",
        }
    }
    pub fn parse(text: &str) -> Option<Self> {
        match text {
            "High quality" => Some(Sampling::HighQuality),
            "Smooth" => Some(Sampling::Smooth),
            "Nearest" => Some(Sampling::Nearest),
            _ => None,
        }
    }
}

impl Serialize for Sampling {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(self.as_str())
    }
}
impl<'de> Deserialize<'de> for Sampling {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let text = String::deserialize(d)?;
        Sampling::parse(&text).ok_or_else(|| serde::de::Error::custom("unknown sampling"))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Default)]
pub struct PointF {
    pub x: f64,
    pub y: f64,
}

impl PointF {
    pub const fn new(x: f64, y: f64) -> Self {
        PointF { x, y }
    }
    pub fn is_finite(self) -> bool {
        self.x.is_finite() && self.y.is_finite()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Default)]
pub struct SizeF {
    pub width: f64,
    pub height: f64,
}

impl SizeF {
    pub const fn new(width: f64, height: f64) -> Self {
        SizeF { width, height }
    }
    pub fn is_finite(self) -> bool {
        self.width.is_finite() && self.height.is_finite()
    }
}

/// An axis-aligned rectangle in document pixels.
#[derive(Clone, Copy, Debug, PartialEq, Default)]
pub struct RectF {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl RectF {
    pub const fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        RectF { x, y, width, height }
    }
    pub fn from_size(size: SizeF) -> Self {
        RectF::new(0.0, 0.0, size.width, size.height)
    }
    pub fn max_x(self) -> f64 {
        self.x + self.width
    }
    pub fn max_y(self) -> f64 {
        self.y + self.height
    }
    pub fn is_finite(self) -> bool {
        self.x.is_finite() && self.y.is_finite() && self.width.is_finite() && self.height.is_finite()
    }
    pub fn contains(self, p: PointF) -> bool {
        p.x >= self.x && p.x < self.max_x() && p.y >= self.y && p.y < self.max_y()
    }
    pub fn union(self, other: RectF) -> RectF {
        let x = self.x.min(other.x);
        let y = self.y.min(other.y);
        RectF::new(x, y, self.max_x().max(other.max_x()) - x, self.max_y().max(other.max_y()) - y)
    }
    pub fn intersection(self, other: RectF) -> Option<RectF> {
        let x = self.x.max(other.x);
        let y = self.y.max(other.y);
        let max_x = self.max_x().min(other.max_x());
        let max_y = self.max_y().min(other.max_y());
        if max_x <= x || max_y <= y {
            None
        } else {
            Some(RectF::new(x, y, max_x - x, max_y - y))
        }
    }
    pub fn intersects(self, other: RectF) -> bool {
        self.intersection(other).is_some()
    }
    /// The smallest integer rectangle covering this one, clipped to the canvas.
    pub fn pixel_bounds(self, width: u32, height: u32) -> Option<(i64, i64, u32, u32)> {
        if !self.is_finite() || self.width <= 0.0 || self.height <= 0.0 {
            return None;
        }
        let x0 = self.x.floor().max(0.0) as i64;
        let y0 = self.y.floor().max(0.0) as i64;
        let x1 = self.max_x().ceil().min(width as f64) as i64;
        let y1 = self.max_y().ceil().min(height as f64) as i64;
        if x1 <= x0 || y1 <= y0 {
            return None;
        }
        Some((x0, y0, (x1 - x0) as u32, (y1 - y0) as u32))
    }
}
/// A 2x3 affine transform: rows [a c tx] and [b d ty].
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Affine {
    pub a: f64,
    pub b: f64,
    pub c: f64,
    pub d: f64,
    pub tx: f64,
    pub ty: f64,
}

impl Affine {
    pub const IDENTITY: Affine = Affine { a: 1.0, b: 0.0, c: 0.0, d: 1.0, tx: 0.0, ty: 0.0 };
    pub const fn new(a: f64, b: f64, c: f64, d: f64, tx: f64, ty: f64) -> Self {
        Affine { a, b, c, d, tx, ty }
    }
    pub fn translation(x: f64, y: f64) -> Self {
        Affine::new(1.0, 0.0, 0.0, 1.0, x, y)
    }
    pub fn scale(x: f64, y: f64) -> Self {
        Affine::new(x, 0.0, 0.0, y, 0.0, 0.0)
    }
    pub fn rotation(degrees: f64) -> Self {
        let r = degrees.to_radians();
        Affine::new(r.cos(), r.sin(), -r.sin(), r.cos(), 0.0, 0.0)
    }
    /// Applies self first, then other.
    pub fn then(self, other: Affine) -> Affine {
        Affine {
            a: other.a * self.a + other.c * self.b,
            b: other.b * self.a + other.d * self.b,
            c: other.a * self.c + other.c * self.d,
            d: other.b * self.c + other.d * self.d,
            tx: other.a * self.tx + other.c * self.ty + other.tx,
            ty: other.b * self.tx + other.d * self.ty + other.ty,
        }
    }
    pub fn apply(self, p: PointF) -> PointF {
        PointF::new(self.a * p.x + self.c * p.y + self.tx, self.b * p.x + self.d * p.y + self.ty)
    }
    pub fn determinant(self) -> f64 {
        self.a * self.d - self.b * self.c
    }
    pub fn inverse(self) -> Option<Affine> {
        let det = self.determinant();
        if det.abs() < 1e-12 {
            return None;
        }
        let ia = self.d / det;
        let ib = -self.b / det;
        let ic = -self.c / det;
        let id = self.a / det;
        Some(Affine::new(ia, ib, ic, id, -(ia * self.tx + ic * self.ty), -(ib * self.tx + id * self.ty)))
    }
    /// The document-space bounding box of the local rectangle 0,0,width,height.
    pub fn bounding_box(self, width: f64, height: f64) -> RectF {
        let corners = [
            self.apply(PointF::new(0.0, 0.0)),
            self.apply(PointF::new(width, 0.0)),
            self.apply(PointF::new(0.0, height)),
            self.apply(PointF::new(width, height)),
        ];
        let mut min_x = f64::INFINITY;
        let mut min_y = f64::INFINITY;
        let mut max_x = f64::NEG_INFINITY;
        let mut max_y = f64::NEG_INFINITY;
        for corner in corners {
            min_x = min_x.min(corner.x);
            min_y = min_y.min(corner.y);
            max_x = max_x.max(corner.x);
            max_y = max_y.max(corner.y);
        }
        RectF::new(min_x, min_y, max_x - min_x, max_y - min_y)
    }
}
/// A layer placement: origin, size, clockwise rotation and flips.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Transform {
    pub origin: PointF,
    pub size: SizeF,
    pub rotation: f64,
    pub flip_x: bool,
    pub flip_y: bool,
    pub sampling: Sampling,
}

impl Default for Transform {
    fn default() -> Self {
        Transform {
            origin: PointF::default(),
            size: SizeF::default(),
            rotation: 0.0,
            flip_x: false,
            flip_y: false,
            sampling: Sampling::HighQuality,
        }
    }
}

impl Transform {
    pub fn new(origin: PointF, size: SizeF) -> Self {
        Transform { origin, size, ..Transform::default() }
    }
    pub fn with_size(width: f64, height: f64) -> Self {
        Transform::new(PointF::default(), SizeF::new(width, height))
    }
    /// Finite, positive extent and finite rotation.
    pub fn is_valid(&self) -> bool {
        self.origin.is_finite()
            && self.size.is_finite()
            && self.size.width > 0.0
            && self.size.height > 0.0
            && self.rotation.is_finite()
    }
    /// Local to document: flip, rotate about the box center, then place.
    pub fn affine(&self) -> Affine {
        let w = self.size.width;
        let h = self.size.height;
        let center = PointF::new(w / 2.0, h / 2.0);
        let mut result = Affine::IDENTITY;
        if self.flip_x {
            result = result.then(Affine::new(-1.0, 0.0, 0.0, 1.0, w, 0.0));
        }
        if self.flip_y {
            result = result.then(Affine::new(1.0, 0.0, 0.0, -1.0, 0.0, h));
        }
        result
            .then(Affine::translation(-center.x, -center.y))
            .then(Affine::rotation(self.rotation))
            .then(Affine::translation(center.x, center.y))
            .then(Affine::translation(self.origin.x, self.origin.y))
    }
    /// The document-space bounding box of this layer box.
    pub fn document_bounds(&self) -> RectF {
        self.affine().bounding_box(self.size.width, self.size.height)
    }
    pub fn full_canvas(width: u32, height: u32) -> Self {
        Transform::with_size(width as f64, height as f64)
    }
}

impl Serialize for Transform {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeStruct;
        let mut st = s.serialize_struct("Transform", 6)?;
        st.serialize_field("origin", &[self.origin.x, self.origin.y])?;
        st.serialize_field("size", &[self.size.width, self.size.height])?;
        st.serialize_field("rotation", &self.rotation)?;
        st.serialize_field("flipX", &self.flip_x)?;
        st.serialize_field("flipY", &self.flip_y)?;
        st.serialize_field("sampling", &self.sampling)?;
        st.end()
    }
}

impl<'de> Deserialize<'de> for Transform {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Raw {
            origin: [f64; 2],
            size: [f64; 2],
            #[serde(default)]
            rotation: f64,
            #[serde(default)]
            flip_x: bool,
            #[serde(default)]
            flip_y: bool,
            sampling: Sampling,
        }
        let raw = Raw::deserialize(d)?;
        Ok(Transform {
            origin: PointF::new(raw.origin[0], raw.origin[1]),
            size: SizeF::new(raw.size[0], raw.size[1]),
            rotation: raw.rotation,
            flip_x: raw.flip_x,
            flip_y: raw.flip_y,
            sampling: raw.sampling,
        })
    }
}

/// An alignment guide. Position is in document pixels along the axis.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Guide {
    #[serde(with = "crate::uuid_text")]
    pub id: uuid::Uuid,
    pub axis: GuideAxis,
    pub position: f64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum GuideAxis {
    Horizontal,
    Vertical,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn affine_places_layer_box() {
        let t = Transform {
            origin: PointF::new(10.0, 20.0),
            size: SizeF::new(100.0, 50.0),
            rotation: 0.0,
            flip_x: false,
            flip_y: false,
            sampling: Sampling::HighQuality,
        };
        let a = t.affine();
        assert_eq!(a.apply(PointF::new(0.0, 0.0)), PointF::new(10.0, 20.0));
        assert_eq!(a.apply(PointF::new(100.0, 50.0)), PointF::new(110.0, 70.0));
        assert_eq!(t.document_bounds(), RectF::new(10.0, 20.0, 100.0, 50.0));
    }

    #[test]
    fn rotation_keeps_center() {
        let t = Transform {
            origin: PointF::new(0.0, 0.0),
            size: SizeF::new(100.0, 100.0),
            rotation: 90.0,
            flip_x: false,
            flip_y: false,
            sampling: Sampling::Smooth,
        };
        let center = t.affine().apply(PointF::new(50.0, 50.0));
        assert!((center.x - 50.0).abs() < 1e-9 && (center.y - 50.0).abs() < 1e-9);
    }

    #[test]
    fn transform_roundtrips_through_json() {
        let t = Transform {
            origin: PointF::new(1.5, -2.0),
            size: SizeF::new(30.0, 40.0),
            rotation: 15.0,
            flip_x: true,
            flip_y: false,
            sampling: Sampling::Nearest,
        };
        let text = serde_json::to_string(&t).unwrap();
        let back: Transform = serde_json::from_str(&text).unwrap();
        assert_eq!(back, t);
        assert!(text.contains("Nearest"));
    }

    #[test]
    fn inverse_roundtrips() {
        let a = Affine::translation(5.0, 7.0).then(Affine::rotation(33.0)).then(Affine::scale(2.0, 3.0));
        let inv = a.inverse().unwrap();
        let p = PointF::new(11.0, -4.0);
        let q = inv.apply(a.apply(p));
        assert!((q.x - p.x).abs() < 1e-9 && (q.y - p.y).abs() < 1e-9);
    }
}
