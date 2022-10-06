# crystal-zip64

An alternate ZIP reader and writer for Crystal.

- Drop-in replacement for `Compress::Zip::Writer`
- Allows you to compress files bigger than 4GB

Extracted from <https://github.com/crystal-lang/crystal/pull/11396>.
Based on <https://github.com/crystal-lang/crystal/pull/7236>.

Inspired by <https://github.com/WeTransfer/cr_zip_tricks>

## Installation

1. Add the dependency to your `shard.yml`:

   ```yaml
   dependencies:
     crystal-zip64:
       github: crystal-garage/crystal-zip64
   ```

2. Run `shards install`

## Usage

```crystal
require "zip64"
```

TODO: Write usage instructions here

## Development

TODO: Write development instructions here

## Contributing

1. Fork it (<https://github.com/crystal-garage/crystal-zip64/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Julik Tarkhanov](https://github.com/julik) - creator and maintainer
- [Anton Maminov](https://github.com/mamantoha) - maintainer
