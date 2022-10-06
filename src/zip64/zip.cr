require "compress/deflate"
require "digest/crc32"

# The `Zip64` module contains readers and writers of the zip
# file format, described at [PKWARE's site](https://pkware.cachefly.net/webdocs/APPNOTE/APPNOTE-6.3.3.TXT).
#
# ### Reading zip files
#
# Two types are provided to read from zip files:
# * `Zip64::File`: can read zip entries from a `File` or from an `IO::Memory`
# and provides random read access to its entries.
# * `Zip64::Reader`: can only read zip entries sequentially from any `IO`.
#
# `Zip64::File` is the preferred method to read zip files if you
# can provide a `File`, because it's a bit more flexible and provides
# more complete information for zip entries (such as comments).
#
# When reading zip files, CRC32 checksum values are automatically
# verified when finishing reading an entry, and `Zip64::Error` will
# be raised if the computed CRC32 checksum does not match.
#
# ### Writer zip files
#
# Use `Zip64::Writer`, which writes zip entries sequentially to
# any `IO`.
#
# NOTE: only compression methods 0 (STORED) and 8 (DEFLATED) are
# supported.
module Zip64
  VERSION                                   =     20_u16
  CENTRAL_DIRECTORY_HEADER_SIGNATURE        = 0x02014b50
  END_OF_CENTRAL_DIRECTORY_HEADER_SIGNATURE = 0x06054b50

  class Error < Exception
  end
end

require "./*"
