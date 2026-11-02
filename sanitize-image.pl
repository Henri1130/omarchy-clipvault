#!/usr/bin/perl
# Re-write a clipboard image into a bounded, metadata-free copy that is safe
# to hand to Qt's Image element in the shared shell.
#
#   sanitize-image.pl IN OUT     -> prints "png" or "jpg" and writes OUT (0600)
#
# Every image ClipVault previews, whether it was copied as image bytes or as a
# file:// path from a download or shared folder, goes through this first. It
# never decompresses anything; it only parses chunk/segment framing:
#   * input must be a regular file of at most CLIPVAULT_IMAGE_MAX bytes
#     (default 50 MiB, same as capture.sh IMAGE_MAX);
#   * width/height must be at most CLIPVAULT_IMAGE_MAX_SIDE (16384) and their
#     product at most CLIPVAULT_IMAGE_MAX_PIXELS (50 MP);
#   * PNG keeps only critical chunks plus small fixed-size colour chunks.
#     tEXt/zTXt/iTXt, iCCP, eXIf, APNG and unknown chunks are dropped, so no
#     compressed side data reaches libpng. CRCs and framing are verified;
#   * JPEG drops COM and APP1-APP13/APP15 (EXIF, XMP, ICC, ...) and keeps
#     JFIF (APP0) and Adobe (APP14).
# Anything else (other formats, truncated or malformed files) is refused with
# a non-zero exit and OUT is not created.
use strict;
use warnings;
use Fcntl qw(O_WRONLY O_CREAT O_EXCL O_RDONLY O_NONBLOCK);
use Compress::Zlib qw(crc32);

umask 077;

sub limit {
  my ($name, $default) = @_;
  my $v = $ENV{$name};
  return (defined $v && $v =~ /^[0-9]+$/ && $v > 0) ? $v : $default;
}

my $MAX_BYTES  = limit('CLIPVAULT_IMAGE_MAX', 50 * 1024 * 1024);
my $MAX_SIDE   = limit('CLIPVAULT_IMAGE_MAX_SIDE', 16384);
my $MAX_PIXELS = limit('CLIPVAULT_IMAGE_MAX_PIXELS', 50_000_000);

sub fail { print STDERR "sanitize-image: $_[0]\n"; exit 1 }

@ARGV == 2 or fail('usage: sanitize-image.pl IN OUT');
my ($in, $out) = @ARGV;

fail('not a regular file') unless -f $in;
my $size = -s _;
fail('empty') unless $size;
fail('too large') if $size > $MAX_BYTES;

sysopen(my $fh, $in, O_RDONLY | O_NONBLOCK) or fail("open: $!");
binmode $fh;
fail('not a regular file') unless -f $fh;
my $data = '';
while (length($data) <= $MAX_BYTES) {
  my $n = sysread($fh, $data, 65536, length $data);
  fail("read: $!") unless defined $n;
  last if $n == 0;
}
close $fh;
fail('too large') if length($data) > $MAX_BYTES;

sub check_dims {
  my ($w, $h) = @_;
  fail('bad dimensions') if $w < 1 || $h < 1;
  fail('dimensions too large') if $w > $MAX_SIDE || $h > $MAX_SIDE || $w * $h > $MAX_PIXELS;
}

# Ancillary PNG chunks that are fixed-size and uncompressed: max data length.
my %PNG_KEEP = (tRNS => 256, gAMA => 4, cHRM => 32, sRGB => 1, pHYs => 9, bKGD => 6, sBIT => 4);

sub sanitize_png {
  my $len = length $data;
  my $clean = substr($data, 0, 8);
  my $pos = 8;
  my ($ihdr, $idat, $iend, $ctype) = (0, 0, 0, -1);
  while ($pos + 12 <= $len) {
    my ($n, $type) = unpack('N a4', substr($data, $pos, 8));
    fail('bad chunk length') if $n > 0x7fffffff || $pos + 12 + $n > $len;
    fail('bad chunk type') unless $type =~ /^[A-Za-z]{4}$/;
    my $body = substr($data, $pos + 4, 4 + $n);
    my ($crc) = unpack('N', substr($data, $pos + 8 + $n, 4));
    fail('bad crc') unless (crc32($body) & 0xffffffff) == $crc;
    my $chunk = substr($data, $pos, 12 + $n);
    $pos += 12 + $n;

    if (!$ihdr) {
      fail('IHDR must come first') unless $type eq 'IHDR' && $n == 13;
      my ($w, $h, $depth, $ct, $comp, $filter, $interlace) = unpack('N N C C C C C', substr($chunk, 8, 13));
      check_dims($w, $h);
      my %ok = (0 => [1, 2, 4, 8, 16], 2 => [8, 16], 3 => [1, 2, 4, 8], 4 => [8, 16], 6 => [8, 16]);
      fail('bad colour type') unless $ok{$ct} && grep { $_ == $depth } @{ $ok{$ct} };
      fail('bad IHDR') if $comp || $filter || $interlace > 1;
      $ctype = $ct;
      $ihdr = 1;
      $clean .= $chunk;
      next;
    }
    fail('duplicate IHDR') if $type eq 'IHDR';
    if ($type eq 'IEND') { $clean .= $chunk; $iend = 1; last }
    if ($type eq 'IDAT') { $clean .= $chunk; $idat = 1; next }
    if ($type eq 'PLTE') {
      fail('bad PLTE') if $n == 0 || $n % 3 || $n > 768;
      $clean .= $chunk;
      next;
    }
    if (exists $PNG_KEEP{$type} && $n <= $PNG_KEEP{$type}) { $clean .= $chunk; next }
    fail('unknown critical chunk') if $type =~ /^[A-Z]/;
    # Everything else (text, iCCP, eXIf, APNG, private) is dropped unread.
  }
  fail('truncated PNG') unless $ihdr && $idat && $iend;
  fail('missing PLTE') if $ctype == 3 && $clean !~ /PLTE/;
  return $clean;
}

my %SOF = map { $_ => 1 } (0xC0 .. 0xC3, 0xC5 .. 0xC7, 0xC9 .. 0xCB, 0xCD .. 0xCF);

sub sanitize_jpeg {
  my $len = length $data;
  my $clean = "\xFF\xD8";
  my $pos = 2;
  my $dims = 0;
  while (1) {
    fail('truncated JPEG') if $pos + 2 > $len;
    fail('bad marker') unless substr($data, $pos, 1) eq "\xFF";
    $pos++ while $pos + 1 < $len && substr($data, $pos + 1, 1) eq "\xFF";
    fail('truncated JPEG') if $pos + 2 > $len;
    my $m = ord substr($data, $pos + 1, 1);
    fail('bad marker') if $m == 0x00 || $m == 0xD8 || $m == 0xD9;
    if ($m == 0x01 || ($m >= 0xD0 && $m <= 0xD7)) { $clean .= "\xFF" . chr($m); $pos += 2; next }
    fail('truncated JPEG') if $pos + 4 > $len;
    my $n = unpack('n', substr($data, $pos + 2, 2));
    fail('bad segment length') if $n < 2 || $pos + 2 + $n > $len;
    my $seg = substr($data, $pos, 2 + $n);
    $pos += 2 + $n;
    if ($SOF{$m}) {
      fail('bad SOF') if $n < 8;
      my ($h, $w) = unpack('n n', substr($seg, 5, 4));
      check_dims($w, $h);
      $dims = 1;
      $clean .= $seg;
    } elsif ($m == 0xDA) {
      fail('scan before frame header') unless $dims;
      # Entropy-coded data and later scans: copied as-is; nothing in them is
      # decompressed into side data, and the frame size above bounds decoding.
      $clean .= $seg . substr($data, $pos);
      fail('missing EOI') unless substr($data, -2) eq "\xFF\xD9";
      return $clean;
    } elsif ($m == 0xFE || ($m >= 0xE1 && $m <= 0xED) || $m == 0xEF) {
      next;    # COM / metadata APPn: dropped
    } else {
      $clean .= $seg;
    }
  }
}

my ($clean, $ext);
if (substr($data, 0, 8) eq "\x89PNG\r\n\x1a\n") {
  ($clean, $ext) = (sanitize_png(), 'png');
} elsif (substr($data, 0, 3) eq "\xFF\xD8\xFF") {
  ($clean, $ext) = (sanitize_jpeg(), 'jpg');
} else {
  fail('unsupported image format');
}

my $oh;
sysopen($oh, $out, O_WRONLY | O_CREAT | O_EXCL, 0600) or do {
  # mktemp callers pre-create OUT; accept an existing empty regular file only.
  fail("output exists: $out") unless -f $out && !-l $out && -z _;
  open($oh, '>', $out) or fail("write: $!");
};
binmode $oh;
print {$oh} $clean or do { close $oh; unlink $out; fail("write: $!") };
close $oh or do { unlink $out; fail("write: $!") };
chmod 0600, $out;
print "$ext\n";
exit 0;
