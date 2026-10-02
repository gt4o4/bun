//! libspng decode/encode for `Bun.Image`. Indexed-PNG encode quantises via
//! `quantize.rs`. Dispatch lives in codecs.rs; this file is the codec body.

use core::ffi::{c_int, c_void};
use core::ptr::NonNull;

use super::codecs;
use super::quantize;

bun_opaque::opaque_ffi! { pub struct spng_ctx; }

unsafe extern "C" {
    fn spng_ctx_new2(alloc: *const SpngAlloc, flags: c_int) -> *mut spng_ctx;
    fn spng_ctx_free(ctx: *mut spng_ctx);
    fn spng_set_png_buffer(ctx: *mut spng_ctx, buf: *const u8, len: usize) -> c_int;
    fn spng_decoded_image_size(ctx: *mut spng_ctx, fmt: c_int, out: *mut usize) -> c_int;
    fn spng_decode_image(
        ctx: *mut spng_ctx,
        out: *mut u8,
        len: usize,
        fmt: c_int,
        flags: c_int,
    ) -> c_int;
    fn spng_get_ihdr(ctx: *mut spng_ctx, ihdr: *mut Ihdr) -> c_int;
    fn spng_set_ihdr(ctx: *mut spng_ctx, ihdr: *const Ihdr) -> c_int;
    fn spng_set_plte(ctx: *mut spng_ctx, plte: *const Plte) -> c_int;
    fn spng_set_trns(ctx: *mut spng_ctx, trns: *const Trns) -> c_int;
    fn spng_encode_image(
        ctx: *mut spng_ctx,
        img: *const u8,
        len: usize,
        fmt: c_int,
        flags: c_int,
    ) -> c_int;
    fn spng_get_png_buffer(ctx: *mut spng_ctx, len: *mut usize, err: *mut c_int) -> *mut u8;
    fn spng_set_option(ctx: *mut spng_ctx, opt: c_int, value: c_int) -> c_int;
    fn spng_set_crc_action(ctx: *mut spng_ctx, critical: c_int, ancillary: c_int) -> c_int;
    /// iCCP chunk read/write — PNG carries an optional ICC profile alongside
    /// the pixels for every colour type (including indexed). `spng_get_iccp`
    /// returns non-zero when the source has no iCCP (or the chunk was
    /// malformed); we treat all non-zero returns the same way — drop the
    /// profile — because the pixels are still valid and a PNG without iCCP
    /// is still a valid PNG. The `profile` pointer it hands back is owned by
    /// the context and freed with `spng_ctx_free`; dupe out before then.
    fn spng_get_iccp(ctx: *mut spng_ctx, iccp: *mut Iccp) -> c_int;
    fn spng_set_iccp(ctx: *mut spng_ctx, iccp: *const Iccp) -> c_int;
}

// A shared libspng can use a different malloc from Bun's local mimalloc
// override. Supply the complete allocator pair so adopted PNG buffers can
// always be freed by the default allocator, including in ASAN builds.
#[repr(C)]
struct SpngAlloc {
    malloc_fn: extern "C" fn(usize) -> *mut c_void,
    realloc_fn: unsafe extern "C" fn(*mut c_void, usize) -> *mut c_void,
    calloc_fn: extern "C" fn(usize, usize) -> *mut c_void,
    free_fn: unsafe extern "C" fn(*mut c_void),
}

extern "C" fn png_malloc(size: usize) -> *mut c_void {
    bun_alloc::default_alloc::malloc(size)
}

unsafe extern "C" fn png_realloc(ptr: *mut c_void, size: usize) -> *mut c_void {
    // SAFETY: libspng only passes null or allocations from this allocator.
    unsafe { bun_alloc::default_alloc::realloc(ptr, size) }
}

extern "C" fn png_calloc(count: usize, size: usize) -> *mut c_void {
    let Some(len) = count.checked_mul(size) else {
        return core::ptr::null_mut();
    };
    let ptr = bun_alloc::default_alloc::malloc(len);
    if !ptr.is_null() {
        // SAFETY: the allocation has room for `len` bytes.
        unsafe { ptr.cast::<u8>().write_bytes(0, len) };
    }
    ptr
}

unsafe extern "C" fn png_free(ptr: *mut c_void) {
    // SAFETY: libspng only passes null or allocations from this allocator.
    unsafe { bun_alloc::default_alloc::free(ptr) };
}

fn new_context(flags: c_int) -> *mut spng_ctx {
    static ALLOCATOR: SpngAlloc = SpngAlloc {
        malloc_fn: png_malloc,
        realloc_fn: png_realloc,
        calloc_fn: png_calloc,
        free_fn: png_free,
    };
    // SAFETY: all four C callbacks are valid and paired. libspng copies the
    // table into the context; the table and callbacks also have static lifetime.
    unsafe { spng_ctx_new2(&raw const ALLOCATOR, flags) }
}

#[repr(C)]
struct Iccp {
    /// PNG's Latin-1 iCCP keyword (1-79 chars + NUL). libspng requires it
    /// non-empty on encode; the PNG spec marks it purely informational
    /// (the profile bytes are what describe the colour space), so on
    /// encode we always write the literal `"ICC Profile"`. The source
    /// keyword is not threaded through `Decoded`.
    profile_name: [u8; 80],
    profile_len: usize,
    profile: *mut u8,
}

#[repr(C)]
#[derive(Default)]
struct Ihdr {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: u8,
    compression_method: u8,
    filter_method: u8,
    interlace_method: u8,
}

const SPNG_CTX_IGNORE_ADLER32: c_int = 1;
const SPNG_CTX_ENCODER: c_int = 2;
const SPNG_CRC_USE: c_int = 2;
const SPNG_FMT_RGBA8: c_int = 1;
const SPNG_FMT_PNG: c_int = 256;
const SPNG_DECODE_TRNS: c_int = 1; // apply tRNS chunk so paletted/grey get real alpha
const SPNG_ENCODE_FINALIZE: c_int = 2;
// spng_option enum
const SPNG_IMG_COMPRESSION_LEVEL: c_int = 2;
const SPNG_ENCODE_TO_BUFFER: c_int = 12;
const SPNG_COLOR_TYPE_INDEXED: u8 = 3;
const SPNG_COLOR_TYPE_TRUECOLOR_ALPHA: u8 = 6;

#[repr(C)]
struct Plte {
    n_entries: u32,
    entries: [[u8; 4]; 256], // r,g,b,alpha(reserved)
}

#[repr(C)]
struct Trns {
    gray: u16,
    red: u16,
    green: u16,
    blue: u16,
    n_type3_entries: u32,
    type3_alpha: [u8; 256],
}

pub(crate) fn decode(bytes: &[u8], max_pixels: u64) -> Result<codecs::Decoded, codecs::Error> {
    // Skip adler32 and chunk-CRC verification (as libvips and stb_image do); they only cost decode time.
    let ctx = new_context(SPNG_CTX_IGNORE_ADLER32);
    if ctx.is_null() {
        return Err(codecs::Error::OutOfMemory);
    }
    let _ctx_guard = scopeguard::guard(ctx, |c| {
        // SAFETY: ctx was returned non-null by new_context and is freed exactly once here.
        unsafe { spng_ctx_free(c) }
    });

    // SAFETY: ctx is valid.
    let _ = unsafe { spng_set_crc_action(ctx, SPNG_CRC_USE, SPNG_CRC_USE) };
    // SAFETY: ctx is valid; bytes outlives the ctx (freed at end of scope).
    if unsafe { spng_set_png_buffer(ctx, bytes.as_ptr(), bytes.len()) } != 0 {
        return Err(codecs::Error::DecodeFailed);
    }
    let mut ihdr = Ihdr::default();
    // SAFETY: ctx is valid; ihdr is a valid out-ptr.
    if unsafe { spng_get_ihdr(ctx, &raw mut ihdr) } != 0 {
        return Err(codecs::Error::DecodeFailed);
    }
    codecs::guard(ihdr.width, ihdr.height, max_pixels)?;
    let mut size: usize = 0;
    // SAFETY: ctx is valid; size is a valid out-ptr.
    if unsafe { spng_decoded_image_size(ctx, SPNG_FMT_RGBA8, &raw mut size) } != 0 {
        return Err(codecs::Error::DecodeFailed);
    }
    let mut out: Vec<u8> = Vec::with_capacity(size);
    // SAFETY: ctx is valid; out has `size` bytes of capacity, which libspng only writes.
    if unsafe {
        spng_decode_image(
            ctx,
            out.as_mut_ptr(),
            size,
            SPNG_FMT_RGBA8,
            SPNG_DECODE_TRNS,
        )
    } != 0
    {
        return Err(codecs::Error::DecodeFailed);
    }
    // SAFETY: libspng returns 0 only once it reached end-of-image, i.e. wrote all `size` bytes.
    unsafe { bun_core::vec::commit_spare(&mut out, size) };

    // iCCP after decode so the chunk has definitely been parsed. A non-zero
    // return here means "no iCCP" or "iCCP was malformed" — treat both as
    // the no-profile case; the pixels are still valid RGBA. `profile` is
    // context-owned memory, so copy it out before `spng_ctx_free` runs at
    // function exit. Propagate OutOfMemory on allocator failure rather
    // than silently degrading colour fidelity — the pixels may be Display
    // P3 / Adobe RGB / XYB, and a "no profile" result there is a visible
    // colour shift, which is the exact bug #30197 is about.
    // SAFETY: all-zero is a valid Iccp (POD; null profile ptr is the "no profile" state).
    let mut iccp: Iccp = unsafe { bun_core::ffi::zeroed_unchecked() };
    // SAFETY: ctx is valid; iccp is a valid out-ptr.
    let icc: Option<Vec<u8>> = if unsafe { spng_get_iccp(ctx, &raw mut iccp) } == 0
        && iccp.profile_len > 0
        && !iccp.profile.is_null()
    {
        // SAFETY: libspng guarantees profile points to profile_len bytes owned by ctx.
        Some(unsafe { core::slice::from_raw_parts(iccp.profile, iccp.profile_len) }.to_vec())
    } else {
        None
    };
    Ok(codecs::Decoded {
        rgba: out,
        width: ihdr.width,
        height: ihdr.height,
        icc_profile: icc,
    })
}

/// Attach `icc_profile` to the encoder as an iCCP chunk. libspng requires
/// `profile_name` non-empty (1-79 Latin-1 chars + NUL) and will deflate the
/// profile payload into the chunk itself. The PNG spec marks the keyword as
/// purely informational, so we write the literal `"ICC Profile"` always —
/// the colour-meaning payload is `p`. A malformed-profile return from
/// libspng drops the profile rather than failing the encode; a PNG without
/// an iCCP is still valid (implicitly sRGB). Called from both truecolour
/// `encode()` and indexed `encode_indexed()` — the PNG spec applies iCCP to
/// every colour type (indexed-colour palettes live in the source space
/// too, so dropping the profile there would silently reinterpret them as
/// sRGB, same bug #30197 was filed for).
fn embed_iccp(ctx: *mut spng_ctx, icc_profile: Option<&[u8]>) {
    let Some(p) = icc_profile else { return };
    if p.is_empty() {
        return;
    }
    let mut iccp = Iccp {
        profile_name: [0u8; 80],
        profile_len: p.len(),
        // `profile` is `char*` in libspng; the library reads-only during
        // encode when `user.iccp = 1` (set by spng_set_iccp). Const-cast
        // to fit the extern-struct field type without duping.
        profile: p.as_ptr().cast_mut(),
    };
    let name = b"ICC Profile";
    iccp.profile_name[..name.len()].copy_from_slice(name);
    // SAFETY: ctx is valid; iccp is fully initialised; libspng only reads from it.
    let _ = unsafe { spng_set_iccp(ctx, &raw const iccp) };
}

pub(crate) fn encode(
    rgba: &[u8],
    w: u32,
    h: u32,
    level: i8,
    icc_profile: Option<&[u8]>,
) -> Result<codecs::Encoded, codecs::Error> {
    let ctx = new_context(SPNG_CTX_ENCODER);
    if ctx.is_null() {
        return Err(codecs::Error::OutOfMemory);
    }
    let _ctx_guard = scopeguard::guard(ctx, |c| {
        // SAFETY: ctx was returned non-null by new_context and is freed exactly once here.
        unsafe { spng_ctx_free(c) }
    });

    // SAFETY: ctx is valid.
    let _ = unsafe { spng_set_option(ctx, SPNG_ENCODE_TO_BUFFER, 1) };
    if level >= 0 {
        // SAFETY: ctx is valid.
        let _ =
            unsafe { spng_set_option(ctx, SPNG_IMG_COMPRESSION_LEVEL, c_int::from(level.min(9))) };
    }
    let ihdr = Ihdr {
        width: w,
        height: h,
        bit_depth: 8,
        color_type: SPNG_COLOR_TYPE_TRUECOLOR_ALPHA,
        ..Default::default()
    };
    // SAFETY: ctx is valid; ihdr is fully initialised.
    if unsafe { spng_set_ihdr(ctx, &raw const ihdr) } != 0 {
        return Err(codecs::Error::EncodeFailed);
    }
    embed_iccp(ctx, icc_profile);
    // SAFETY: ctx is valid; rgba is a valid readable buffer.
    if unsafe {
        spng_encode_image(
            ctx,
            rgba.as_ptr(),
            rgba.len(),
            SPNG_FMT_PNG,
            SPNG_ENCODE_FINALIZE,
        )
    } != 0
    {
        return Err(codecs::Error::EncodeFailed);
    }
    let mut len: usize = 0;
    let mut err: c_int = 0;
    // SAFETY: ctx is valid; len/err are valid out-ptrs.
    let buf = unsafe { spng_get_png_buffer(ctx, &raw mut len, &raw mut err) };
    if buf.is_null() {
        return Err(codecs::Error::EncodeFailed);
    }
    // spng_get_png_buffer transfers ownership; hand to JS with the same
    // default allocator as the context instead of duping.
    // SAFETY: buf is non-null and points to `len` bytes from the context's default allocator.
    let bytes = unsafe { NonNull::new_unchecked(core::ptr::slice_from_raw_parts_mut(buf, len)) };
    Ok(codecs::Encoded {
        bytes,
        free: bun_alloc::c_thunks::mi_free_bytes,
    })
}

/// Quantize RGBA to ≤ `colors` and emit an indexed (colour-type 3) PNG
/// with PLTE + tRNS. The quantizer is a small median-cut — see
/// quantize.rs. `icc_profile` carries the source colour space; median
/// cut operates on the raw RGB numbers without converting colour spaces,
/// so the palette entries are still in that space and need the profile
/// to be interpreted correctly — same contract as truecolour encode.
pub(crate) fn encode_indexed(
    rgba: &[u8],
    w: u32,
    h: u32,
    level: i8,
    colors: u16,
    dither: bool,
    icc_profile: Option<&[u8]>,
) -> Result<codecs::Encoded, codecs::Error> {
    let q = quantize::quantize(
        rgba,
        w,
        h,
        quantize::Options {
            max_colors: colors,
            dither,
        },
    )
    .map_err(|_| codecs::Error::OutOfMemory)?;

    let ctx = new_context(SPNG_CTX_ENCODER);
    if ctx.is_null() {
        return Err(codecs::Error::OutOfMemory);
    }
    let _ctx_guard = scopeguard::guard(ctx, |c| {
        // SAFETY: ctx was returned non-null by new_context and is freed exactly once here.
        unsafe { spng_ctx_free(c) }
    });

    // SAFETY: ctx is valid.
    let _ = unsafe { spng_set_option(ctx, SPNG_ENCODE_TO_BUFFER, 1) };
    if level >= 0 {
        // SAFETY: ctx is valid.
        let _ =
            unsafe { spng_set_option(ctx, SPNG_IMG_COMPRESSION_LEVEL, c_int::from(level.min(9))) };
    }

    let ihdr = Ihdr {
        width: w,
        height: h,
        bit_depth: 8,
        color_type: SPNG_COLOR_TYPE_INDEXED,
        ..Default::default()
    };
    // SAFETY: ctx is valid; ihdr is fully initialised.
    if unsafe { spng_set_ihdr(ctx, &raw const ihdr) } != 0 {
        return Err(codecs::Error::EncodeFailed);
    }
    embed_iccp(ctx, icc_profile);

    let mut plte = Plte {
        n_entries: u32::from(q.colors),
        entries: [[0u8; 4]; 256],
    };
    let mut trns = Trns {
        gray: 0,
        red: 0,
        green: 0,
        blue: 0,
        n_type3_entries: u32::from(q.colors),
        type3_alpha: [0u8; 256],
    };
    for i in 0..(q.colors as usize) {
        plte.entries[i] = [
            q.palette[i * 4],
            q.palette[i * 4 + 1],
            q.palette[i * 4 + 2],
            255,
        ];
        trns.type3_alpha[i] = q.palette[i * 4 + 3];
    }
    // SAFETY: ctx is valid; plte is fully initialised.
    if unsafe { spng_set_plte(ctx, &raw const plte) } != 0 {
        return Err(codecs::Error::EncodeFailed);
    }
    // SAFETY: ctx is valid; trns is fully initialised.
    if q.has_alpha && unsafe { spng_set_trns(ctx, &raw const trns) } != 0 {
        return Err(codecs::Error::EncodeFailed);
    }

    // SAFETY: ctx is valid; q.indices is a valid readable buffer.
    if unsafe {
        spng_encode_image(
            ctx,
            q.indices.as_ptr(),
            q.indices.len(),
            SPNG_FMT_PNG,
            SPNG_ENCODE_FINALIZE,
        )
    } != 0
    {
        return Err(codecs::Error::EncodeFailed);
    }

    let mut len: usize = 0;
    let mut err: c_int = 0;
    // SAFETY: ctx is valid; len/err are valid out-ptrs.
    let buf = unsafe { spng_get_png_buffer(ctx, &raw mut len, &raw mut err) };
    if buf.is_null() {
        return Err(codecs::Error::EncodeFailed);
    }
    // SAFETY: buf is non-null and points to `len` bytes from the context's default allocator.
    let bytes = unsafe { NonNull::new_unchecked(core::ptr::slice_from_raw_parts_mut(buf, len)) };
    Ok(codecs::Encoded {
        bytes,
        free: bun_alloc::c_thunks::mi_free_bytes,
    })
}
