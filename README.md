# crystal-zip64

[![Crystal CI](https://github.com/crystal-garage/crystal-zip64/actions/workflows/crystal.yml/badge.svg)](https://github.com/crystal-garage/crystal-zip64/actions/workflows/crystal.yml)
[![GitHub release](https://img.shields.io/github/release/crystal-garage/crystal-zip64.svg)](https://github.com/crystal-garage/crystal-zip64/releases)
[![Commits Since Last Release](https://img.shields.io/github/commits-since/crystal-garage/crystal-zip64/latest.svg)](https://github.com/crystal-garage/crystal-zip64/pulse)
[![Docs](https://img.shields.io/badge/docs-available-brightgreen.svg)](https://crystal-garage.github.io/crystal-zip64/)
[![License](https://img.shields.io/github/license/crystal-garage/crystal-zip64.svg)](https://github.com/crystal-garage/crystal-zip64/blob/master/LICENSE)

An alternate ZIP reader and writer for Crystal.

- Drop-in replacement for `Compress::Zip`
- Allows you to compress files bigger than 4GB
- Tested on Linux, macOS and Windows

Extracted from <https://github.com/crystal-lang/crystal/pull/11396>.
Based on <https://github.com/crystal-lang/crystal/pull/7236>.

Inspired by <https://github.com/WeTransfer/cr_zip_tricks>

## Installation

1. Add the dependency to your `shard.yml`:

   ```yaml
   dependencies:
     zip64:
       github: crystal-garage/crystal-zip64
   ```

2. Run `shards install`

## Usage

```crystal
require "zip64"
```

### Reader

```crystal
Compress::Zip64::Reader.open("./file.zip") do |zip|
  zip.each_entry do |entry|
    p entry.filename
    p entry.file?
    p entry.dir?
    p entry.io.gets_to_end
  end
end
```

### Writer

```crystal
File.open("./file.zip", "w") do |file|
  Compress::Zip64::Writer.open(file) do |zip|
    # Add a file with a String content
    zip.add "foo.txt", "contents of foo"

    # Add a file and write data to it through an IO
    zip.add("bar.txt") do |io|
      io << "contents of bar"
    end

    # Add a file by referencing a file in the filesystem
    # (the file is automatically closed after this call)
    zip.add("baz.txt", File.open("./some_file.txt"))
  end
end
```

## Contributing

1. Fork it (<https://github.com/crystal-garage/crystal-zip64/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Julik Tarkhanov](https://github.com/julik) - creator and maintainer
- [Anton Maminov](https://github.com/mamantoha) - maintainer
