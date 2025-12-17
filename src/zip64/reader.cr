require "./file_info"

# Reads zip file entries sequentially from an `IO`.
#
# NOTE: Entries might not have correct values
# for crc32, compressed_size, uncompressed_size and comment,
# because when reading a zip file directly from a stream this
# information might be stored later in the zip stream.
# If you need this information, consider using `Zip64::File`.
#
# ### Example
#
# ```
# require "zip64"
#
# Zip64::Reader.open("./file.zip") do |zip|
#   zip.each_entry do |entry|
#     p entry.filename
#     p entry.file?
#     p entry.dir?
#     p entry.io.gets_to_end
#   end
# end
# ```
class Zip64::Reader
  # Whether to close the enclosed `IO` when closing this reader.
  property? sync_close = false

  # Returns `true` if this reader is closed.
  getter? closed = false

  # Creates a new reader from the given *io*.
  def initialize(@io : IO, @sync_close = false)
    @reached_end = false
    @read_data_descriptor = true
  end

  # Creates a new reader from the given *filename*.
  def self.new(filename : Path | String)
    new(::File.new(filename), sync_close: true)
  end

  # Creates a new reader from the given *io*, yields it to the given block,
  # and closes it at the end.
  def self.open(io : IO, sync_close = false, &)
    reader = new(io, sync_close: sync_close)
    yield reader ensure reader.close
  end

  # Creates a new reader from the given *filename*, yields it to the given block,
  # and closes it at the end.
  def self.open(filename : Path | String, &)
    reader = new(filename)
    yield reader ensure reader.close
  end

  # Reads the next entry in the zip, or `nil` if there
  # are no more entries.
  #
  # After reading a next entry, previous entries can no
  # longer be read (their `IO` will be closed.)
  def next_entry : Entry?
    return if @reached_end

    if last_entry = @last_entry
      last_entry.close
      skip_data_descriptor(last_entry)
    end

    loop do
      signature = read UInt32

      case signature
      when FileInfo::SIGNATURE
        # Found file info signature
        break
      when FileInfo::DATA_DESCRIPTOR_SIGNATURE
        if last_entry && !@read_data_descriptor
          # Consider the case where a data descriptor comes after
          # a STORED entry: skip data descriptor and expect file signature next
          read_data_descriptor(last_entry)
          next
        else
          raise Error.new("Unexpected data descriptor when reading zip")
        end
      else
        # Other signature: we are done with entries (next comes metadata)
        @reached_end = true
        return
      end
    end

    @last_entry = Entry.new(@io)
  end

  # Yields each entry in the zip to the given block.
  def each_entry(&)
    while entry = next_entry
      yield entry
    end
  end

  # Closes this zip reader.
  def close : Nil
    return if @closed
    @closed = true
    @io.close if @sync_close
  end

  private def skip_data_descriptor(entry)
    if entry.compression_method.deflated? && entry.bit_3_set?
      # The data descriptor signature is optional: if we
      # find it, we read the data descriptor info normally;
      # otherwise, the first four bytes are the crc32 value.
      signature = read UInt32
      if signature == FileInfo::DATA_DESCRIPTOR_SIGNATURE
        read_data_descriptor(entry)
      else
        read_data_descriptor(entry, crc32: signature)
      end
      @read_data_descriptor = true
    else
      @read_data_descriptor = false
      verify_checksum(entry)
    end
  end

  private def read_data_descriptor(entry, crc32 = nil)
    entry.crc32 = crc32 || (read UInt32)
    if data_descriptor_uses_zip64_sizes?
      entry.compressed_size = read(UInt64)
      entry.uncompressed_size = read(UInt64)
    else
      entry.compressed_size = read(UInt32).to_u64
      entry.uncompressed_size = read(UInt32).to_u64
    end
    verify_checksum(entry)
  end

  private def data_descriptor_uses_zip64_sizes? : Bool
    # After CRC32 in a data descriptor, sizes are either:
    # - 4 + 4 bytes (standard)
    # - 8 + 8 bytes (Zip64)
    # We try to detect by peeking ahead and checking which offset is followed
    # by a valid next record signature.
    peek = @io.peek
    return false unless peek

    # If sizes are 4+4, the next signature begins 8 bytes from the current position.
    if peek.size >= 12 && valid_next_record_signature?(uint32_le_at(peek, 8))
      # If both look plausible, prefer 32-bit unless only 64-bit matches.
      if peek.size >= 20 && valid_next_record_signature?(uint32_le_at(peek, 16))
        return false
      end
      return false
    end

    if peek.size >= 20 && valid_next_record_signature?(uint32_le_at(peek, 16))
      return true
    end

    false
  end

  private def valid_next_record_signature?(sig : UInt32) : Bool
    sig == FileInfo::SIGNATURE ||
      sig == Zip64::CENTRAL_DIRECTORY_HEADER_SIGNATURE ||
      sig == Zip64::END_OF_CENTRAL_DIRECTORY_HEADER_SIGNATURE ||
      sig == FileInfo::DATA_DESCRIPTOR_SIGNATURE
  end

  private def uint32_le_at(bytes : Bytes, offset : Int32) : UInt32
    IO::Memory.new(bytes[offset, 4]).read_bytes(UInt32, IO::ByteFormat::LittleEndian)
  end

  private def verify_checksum(entry)
    if entry.crc32 != entry.checksum_io.crc32
      raise Zip64::Error.new("Checksum failed for entry #{entry.filename} (expected #{entry.crc32}, got #{entry.checksum_io.crc32}")
    end
  end

  private def read(type)
    @io.read_bytes(type, IO::ByteFormat::LittleEndian)
  end

  # A entry inside a `Zip64::Reader`.
  #
  # Use the `io` method to read from it.
  class Entry
    include FileInfo

    # :nodoc:
    def initialize(io)
      super(at_file_header: io)
      @io = ChecksumReader.new(decompressor_for(io), @filename)
      @closed = false
    end

    # Returns an `IO` to the entry's data.
    def io : IO
      @io
    end

    protected def checksum_io
      @io
    end

    protected def close
      return if @closed
      @closed = true
      @io.skip_to_end
      @io.close
    end
  end
end
