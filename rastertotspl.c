/*
 * CUPS raster to TSPL for the Coibeu WKDY-81X.
 * macOS converts PDF through cgpdftoraster. LABELCORE inverts each bitmap
 * byte, and the WKDY-81X burns a cleared bit, so this filter does the same.
 * Vendor defaults copied from that DLL: DENSITY 8, SPEED 8, SET TEAR ON,
 * and a 3 mm gap when the stored gap height is 0.
 */

#include <cups/raster.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define DPI_FALLBACK 203

static double gap_mm(const char *options)
{
  const char *found;

  if (options == NULL)
    return 3.0;
  found = strstr(options, "GapMm=");
  if (found == NULL)
    return 3.0;
  found += 6;
  if (strncmp(found, "Gap0", 4) == 0)
    return 0.0;
  if (strncmp(found, "Gap3", 4) == 0)
    return 3.0;
  if (strncmp(found, "Gap2", 4) == 0)
    return 2.0;
  return strtod(found, NULL);
}

static int copies_from_args(int argc, char **argv)
{
  int copies = 1;

  if (argc > 4)
    copies = atoi(argv[4]);
  if (copies < 1)
    copies = 1;
  return copies;
}

/* Channels at or above this stay unburned paper. A 50% luminance cut maps
 * the J&T red (255, 0, 26) to white. Thermal stock is 1 bit, so any pixel
 * that is not paper-white burns as a solid dot, matching the preview.
 */
#define PAPER_LEVEL 250

static int pixel_is_ink(
    const unsigned char *row,
    unsigned x,
    unsigned color_space,
    unsigned bits_per_pixel,
    unsigned bits_per_color)
{
  unsigned byte_index;
  unsigned value;
  unsigned red;
  unsigned green;
  unsigned blue;

  if (bits_per_pixel <= 1) {
    byte_index = x / 8;
    value = (row[byte_index] >> (7 - (x % 8))) & 0x1;
    if (color_space == CUPS_CSPACE_K)
      return value != 0;
    return value == 0;
  }

  byte_index = x * (bits_per_pixel / 8);
  if (bits_per_color >= 8 && bits_per_pixel >= 24) {
    if (color_space == CUPS_CSPACE_CMYK || color_space == CUPS_CSPACE_YMCK ||
        color_space == CUPS_CSPACE_KCMY) {
      unsigned channel;
      unsigned channels = bits_per_pixel / 8;
      if (channels > 4)
        channels = 4;
      for (channel = 0; channel < channels; channel++) {
        if (row[byte_index + channel] > (255 - PAPER_LEVEL))
          return 1;
      }
      return 0;
    }
    red = row[byte_index];
    green = row[byte_index + 1];
    blue = row[byte_index + 2];
    return red < PAPER_LEVEL || green < PAPER_LEVEL || blue < PAPER_LEVEL;
  }

  value = row[byte_index];
  if (color_space == CUPS_CSPACE_K)
    return value > (255 - PAPER_LEVEL);
  return value < PAPER_LEVEL;
}

static int write_page(
    const cups_page_header2_t *header,
    const unsigned char *pixels,
    double gap,
    int copies)
{
  unsigned dpi;
  unsigned width;
  unsigned height;
  unsigned stride;
  unsigned row_bytes;
  unsigned x;
  unsigned y;
  unsigned char *bitmap;
  double width_mm;
  double height_mm;

  width = header->cupsWidth;
  height = header->cupsHeight;
  stride = header->cupsBytesPerLine;
  if (width == 0 || height == 0 || stride == 0) {
    fprintf(stderr, "rastertotspl: empty page\n");
    return 0;
  }
  if (header->cupsBitsPerPixel == 0) {
    fprintf(stderr, "rastertotspl: unsupported pixel format\n");
    return 0;
  }
  dpi = header->HWResolution[0] ? header->HWResolution[0] : DPI_FALLBACK;
  row_bytes = (width + 7) / 8;
  bitmap = malloc((size_t)row_bytes * height);
  if (bitmap == NULL)
    return 0;
  memset(bitmap, 0xFF, (size_t)row_bytes * height);

  for (y = 0; y < height; y++) {
    const unsigned char *row = pixels + (size_t)y * stride;
    for (x = 0; x < width; x++) {
      if (!pixel_is_ink(
              row,
              x,
              header->cupsColorSpace,
              header->cupsBitsPerPixel,
              header->cupsBitsPerColor))
        continue;
      bitmap[(size_t)y * row_bytes + (x / 8)] &= (unsigned char)~(0x80 >> (x % 8));
    }
  }

  width_mm = (double)width / (double)dpi * 25.4;
  height_mm = (double)height / (double)dpi * 25.4;
  if (printf(
          "SIZE %.2f mm, %.2f mm\r\n"
          "DIRECTION 1\r\n"
          "GAP %.2f mm, 0 mm\r\n"
          "DENSITY 8\r\n"
          "SPEED 8\r\n"
          "SET TEAR ON\r\n"
          "CLS\r\n"
          "BITMAP 0,0,%u,%u,0,",
          width_mm,
          height_mm,
          gap < 0 ? 0 : gap,
          row_bytes,
          height) < 0) {
    free(bitmap);
    return 0;
  }
  if (fwrite(bitmap, 1, (size_t)row_bytes * height, stdout) != (size_t)row_bytes * height) {
    free(bitmap);
    return 0;
  }
  free(bitmap);
  if (printf("\r\nPRINT %d,1\r\n", copies) < 0)
    return 0;
  return 1;
}

int main(int argc, char **argv)
{
  int fd = 0;
  int copies;
  double gap;
  cups_raster_t *raster;
  cups_page_header2_t header;
  unsigned char *pixels = NULL;
  size_t pixels_size = 0;
  int pages = 0;

  copies = copies_from_args(argc, argv);
  gap = gap_mm(argc > 5 ? argv[5] : "");
  if (argc > 6) {
    fd = open(argv[6], O_RDONLY);
    if (fd < 0) {
      fprintf(stderr, "rastertotspl: %s\n", strerror(errno));
      return 1;
    }
  }

  raster = cupsRasterOpen(fd, CUPS_RASTER_READ);
  if (raster == NULL) {
    fprintf(stderr, "rastertotspl: cupsRasterOpen failed\n");
    if (fd > 0)
      close(fd);
    return 1;
  }

  while (cupsRasterReadHeader2(raster, &header)) {
    size_t nbytes = (size_t)header.cupsBytesPerLine * (size_t)header.cupsHeight;
    if (nbytes == 0 || nbytes > 16 * 1024 * 1024) {
      fprintf(stderr, "rastertotspl: page size rejected\n");
      cupsRasterClose(raster);
      free(pixels);
      if (fd > 0)
        close(fd);
      return 1;
    }
    if (nbytes > pixels_size) {
      unsigned char *grown = realloc(pixels, nbytes);
      if (grown == NULL) {
        cupsRasterClose(raster);
        free(pixels);
        if (fd > 0)
          close(fd);
        return 1;
      }
      pixels = grown;
      pixels_size = nbytes;
    }
    if (cupsRasterReadPixels(raster, pixels, (unsigned)nbytes) < (unsigned)nbytes) {
      fprintf(stderr, "rastertotspl: short raster read\n");
      cupsRasterClose(raster);
      free(pixels);
      if (fd > 0)
        close(fd);
      return 1;
    }
    if (!write_page(&header, pixels, gap, copies)) {
      cupsRasterClose(raster);
      free(pixels);
      if (fd > 0)
        close(fd);
      return 1;
    }
    pages++;
  }

  cupsRasterClose(raster);
  free(pixels);
  if (fd > 0)
    close(fd);
  if (pages == 0) {
    fprintf(stderr, "rastertotspl: no pages\n");
    return 1;
  }
  return 0;
}
