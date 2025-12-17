require "./file_info"

# Provides random read access to zip file entries stores inside
# a `File` or an `IO::Memory`.
#
# ### Example
#
# ```
# require "zip64"
#
# Zip64::File.open("./file.zip") do |file|
#   # Iterate through all entries printing their filename and contents
#   file.entries.each do |entry|
#     p entry.filename
#     entry.open do |io|
#       p io.gets_to_end
#     end
#   end
#
#   # Random access to entries by filename is also provided
#   entry = file["some_file.txt"]
#   entry.open do |io|
#     p io.gets_to_end
#   end
# end
# ```
class Zip64::File
  # Returns all entries inside this zip file.
  getter entries : Array(Entry)

  # Returns `true` if this zip file is closed.
  getter? closed = false

  # Returns the zip file comment.
  getter comment = ""

  @source_path : String?

  # Opens a `Zip64::File` for reading from the given *io*.
  def initialize(@io : IO, @sync_close = false)
    if @io.is_a?(::File)
      @source_path = @io.as(::File).path
    end

    directory_end_offset = find_directory_end_offset
    entries_size, directory_offset = read_directory_end(directory_end_offset)
    @entries = Array(Entry).new(entries_size)
    @entries_by_filename = {} of String => Entry
    read_entries(directory_offset, entries_size)
  end

  # Opens a `Zip64::File` for reading from the given *filename*.
  def self.new(filename : Path | String)
    new(::File.new(filename), sync_close: true)
  end

  # Opens a `Zip64::File` for reading from the given *io*, yields
  # it to the given block, and closes it at the end.
  def self.open(io : IO, sync_close = false, &)
    zip = new io, sync_close
    yield zip ensure zip.close
  end

  # Opens a `Zip64::File` for reading from the given *filename*, yields
  # it to the given block, and closes it at the end.
  def self.open(filename : Path | String, &)
    zip = new filename
    yield zip ensure zip.close
  end

  # Returns the entry that has the given filename, or
  # raises `KeyError` if no such entry exists.
  def [](filename : Path | String) : Entry
    self[filename]? || raise(KeyError.new("Missing zip entry: #{filename}"))
  end

  # Returns the entry that has the given filename, or
  # `nil` if no such entry exists.
  def []?(filename : Path | String) : Entry?
    @entries_by_filename[filename.to_s]?
  end

  # Closes this zip file.
  def close : Nil
    return if @closed
    @closed = true
    if @sync_close
      @io.close
    end
  end

  # Tries to find the directory end offset (by searching its signature)
  # in the last 64, 1024 and 65K bytes (in that order)
  private def find_directory_end_offset
    find_directory_end_offset(64) ||
      find_directory_end_offset(1024) ||
      find_directory_end_offset(65 * 1024) ||
      raise Zip64::Error.new("Couldn't find directory end signature in the last 65KB")
  end

  private def find_directory_end_offset(buf_size)
    @io.seek(0, IO::Seek::End)
    size = @io.pos

    buf_size = Math.min(buf_size, size)
    @io.pos = size - buf_size

    buf = Bytes.new(buf_size)
    @io.read_fully(buf)

    i = buf_size - 1 - 4
    while i >= 0
      # These are the bytes the make up the directory end signature,
      # according to the spec
      break if buf[i] == 0x50 && buf[i + 1] == 0x4b && buf[i + 2] == 0x05 && buf[i + 3] == 0x06
      i -= 1
    end

    i == -1 ? nil : size - buf_size + i
  end

  private def read_directory_end(directory_end_offset)
    @io.pos = directory_end_offset

    signature = read UInt32
    if signature != Zip64::END_OF_CENTRAL_DIRECTORY_HEADER_SIGNATURE
      raise Error.new("Expected end of central directory header signature, not 0x#{signature.to_s(16)}")
    end

    read UInt16                              # number of this disk
    read UInt16                              # disk start
    entries_in_disk = read(UInt16)           # number of entries in disk
    entries_size_16 = read(UInt16)           # number of total entries
    central_directory_size_32 = read(UInt32) # size of the central directory
    directory_offset_32 = read(UInt32)       # offset of central directory
    comment_length = read(UInt16)            # comment length
    if comment_length != 0
      @comment = @io.read_string(comment_length)
    end

    zip64_required = entries_in_disk == UInt16::MAX ||
                     entries_size_16 == UInt16::MAX ||
                     central_directory_size_32 == UInt32::MAX ||
                     directory_offset_32 == UInt32::MAX

    if zip64_required
      entries_size_64, directory_offset_64 = read_zip64_directory_end(directory_end_offset)
      entries_size = entries_size_64
      directory_offset = directory_offset_64
    else
      entries_size = entries_size_16.to_u64
      directory_offset = directory_offset_32.to_u64
    end

    if entries_size > Int32::MAX.to_u64
      raise Zip64::Error.new("Too many entries to load into memory: #{entries_size}")
    end
    if directory_offset > Int64::MAX.to_u64
      raise Zip64::Error.new("Central directory offset is too large: #{directory_offset}")
    end

    {entries_size.to_i, directory_offset.to_u64}
  end

  private def read_zip64_directory_end(directory_end_offset : Int)
    # Zip64 locator is 20 bytes and immediately precedes the EOCD record.
    locator_offset = directory_end_offset.to_i64 - 20
    if locator_offset < 0
      raise Zip64::Error.new("Zip64 locator offset is negative")
    end

    @io.pos = locator_offset
    signature = read UInt32
    if signature != Zip64::ZIP64_END_OF_CENTRAL_DIRECTORY_LOCATOR
      raise Zip64::Error.new("Expected Zip64 locator signature, not 0x#{signature.to_s(16)}")
    end

    read UInt32 # number of the disk with the start of the zip64 end of central directory
    zip64_eocd_offset = read(UInt64)
    read UInt32 # total number of disks

    if zip64_eocd_offset > Int64::MAX.to_u64
      raise Zip64::Error.new("Zip64 EOCD offset is too large: #{zip64_eocd_offset}")
    end

    @io.pos = zip64_eocd_offset.to_i64
    signature = read UInt32
    if signature != Zip64::ZIP64_END_OF_CENTRAL_DIRECTORY_SIGNATURE
      raise Zip64::Error.new("Expected Zip64 EOCD signature, not 0x#{signature.to_s(16)}")
    end

    size_of_record = read UInt64
    # Next: version made by (2), version needed (2), disk number (4), disk start (4)
    read UInt16
    read UInt16
    read UInt32
    read UInt32

    _entries_in_disk = read UInt64
    entries_total = read UInt64
    _central_directory_size = read UInt64
    directory_offset = read UInt64

    # Skip any extensible data sector if present
    remaining = size_of_record.to_i64 - 44
    if remaining > 0
      @io.skip(remaining)
    end

    {entries_total, directory_offset}
  end

  private def read_entries(directory_offset, entries_size)
    @io.pos = directory_offset.to_i64

    entries_size.times do
      signature = read UInt32
      if signature != Zip64::CENTRAL_DIRECTORY_HEADER_SIGNATURE
        raise Error.new("Expected directory header signature, not 0x#{signature.to_s(16)}")
      end

      entry = Entry.new(@io, @source_path)
      @entries << entry
      @entries_by_filename[entry.filename] = entry
    end
  end

  private def read(type)
    @io.read_bytes(type, IO::ByteFormat::LittleEndian)
  end

  # An entry inside a `Zip64::File`.
  #
  # Use the `open` method to read from it.
  class Entry
    include FileInfo

    @source_path : String?

    # :nodoc:
    def initialize(@io : IO, @source_path : String? = nil)
      super(at_central_directory_header: io)
    end

    # Yields an `IO` to read this entry's contents.
    # Multiple entries can be opened and read concurrently.
    def open(&)
      if path = @source_path
        ::File.open(path, "r") do |file|
          file.pos = to_i64_checked(offset, "local header offset")
          file.pos = to_i64_checked(data_offset_from(file), "entry data offset")
          sized = IO::Sized.new(file, to_i64_checked(compressed_size, "entry compressed size"))
          io = decompressor_for(sized, is_sized: true)
          checksum_reader = ChecksumReader.new(io, filename, verify: crc32)
          yield checksum_reader
        end
      else
        @io.read_at(to_i32_checked(data_offset, "entry data offset"), to_i32_checked(compressed_size, "entry compressed size")) do |io|
          io = decompressor_for(io, is_sized: true)
          checksum_reader = ChecksumReader.new(io, filename, verify: crc32)
          yield checksum_reader
        end
      end
    end

    private getter(data_offset : UInt64) do
      # Apparently a zip entry might have different extra bytes
      # in the local file header and central directory header,
      # so to know the data offset we must read them again.
      #
      # The bytes inside a local file header, from the signature
      # and up to the extra length field, sum up 30 bytes.
      #
      # This 30 and 22 constants are burned inside the zip spec and
      # will never change.
      @io.read_at(to_i32_checked(offset, "local header offset"), 30) do |io|
        data_offset_from(io)
      end
    end

    private def data_offset_from(io : IO) : UInt64
      # Read and validate local file header.
      signature = read(io, UInt32)
      if signature != FileInfo::SIGNATURE
        raise Zip64::Error.new("Wrong local file header signature (expected 0x#{FileInfo::SIGNATURE.to_s(16)}, got 0x#{signature.to_s(16)})")
      end

      # Skip most of the headers except filename length and extra length
      # (skip 22, so we already read 26 bytes)
      io.skip(22)

      # With these two we read 4 bytes more, so we are at 30 bytes
      filename_length = read(io, UInt16)
      extra_length = read(io, UInt16)

      @offset + 30 + filename_length + extra_length
    end

    private def to_i32_checked(value : UInt64, label : String) : Int32
      if value > Int32::MAX.to_u64
        raise Zip64::Error.new("#{label} is too large for IO#read_at: #{value}")
      end
      value.to_i32
    end

    private def to_i64_checked(value : UInt64, label : String) : Int64
      if value > Int64::MAX.to_u64
        raise Zip64::Error.new("#{label} is too large: #{value}")
      end
      value.to_i64
    end
  end
end
