# fluent-plugin-file2

[![Build Status](https://secure.travis-ci.org/sonots/fluent-plugin-file2.png?branch=master)](http://travis-ci.org/sonots/fluent-plugin-file2)

Re-implementation of out\_file plugin for Fluentd.

## Problems

1. `out_file` plugin is not thread-safe and process-safe. See http://d.hatena.ne.jp/sfujiwara/20121027/1351330488 (Japanese)
2. `out_file` plugin creates multiple separated buffer files on running multiple threads (and processes). Want to write into one file cuncurrently from multiple threads (and processes).

## Strategy

The fundamental strategy to solve above problems is:

Specify `path` with time format, and just append contents to the strftime filename from multiple threads (and processes). No buffer file is generated anymore.
This is the same strategy with [strftime_logger](https://github.com/sonots/strftime_logger), which is already running on a production environment.

## How to Use

Basically same with out\_file plugin. See the doc of [out_file](http://docs.fluentd.org/articles/out_file). 

## Differences

Differences with `out_file`:

* No buffer file is generated.
* `append true|false` option was removed. Always `append true`. 
* Filename is expanded using the current time, rahter than the time in a chunk. 

## ToDo

* `compress` option is not implemented yet
  * Need to implement carefully to achieve thread-safety.

## ChangeLog

See [CHANGELOG.md](CHANGELOG.md) for details.

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new [Pull Request](../../pull/new/master)

## Copyright

Copyright (c) 2014 Naotoshi Seo. See [LICENSE](LICENSE) for details.

