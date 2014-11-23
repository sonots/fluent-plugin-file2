# fluent-plugin-file2

[![Build Status](https://secure.travis-ci.org/sonots/fluent-plugin-file2.png?branch=master)](http://travis-ci.org/sonots/fluent-plugin-file2)

Re-implementation of out\_file plugin for Fluentd.

## Problems

1. `out_file` plugin is not thread-safe and process-safe. See http://d.hatena.ne.jp/sfujiwara/20121027/1351330488 (Japanese)
2. `out_file` plugin creates multiple separated buffer files on running multiple threads (and processes). Want to write into one file cuncurrently from multiple threads (and processes).

## Strategy

The fundamental strategy to solve above problems is:

Specify `path` with time format, and just append contents to the strftime filename from multiple threads (and processes). No buffer file is generated anymore.
This is the same strategy with [strftime_logger](https://github.com/sonots/strftime_logger), which is already running on my production environment.

For compression, compress a previously generate file on another thread in each interval implied by the time format in the `path` parameter. 
The thread and process safety was achieved by a delicate implementation although I think running another cron job for compression is better approach. 

## How to Use

Basically same with out\_file plugin. You may see the doc of [out_file](http://docs.fluentd.org/articles/out_file). 

* path

    The path of the file such as `foo.%Y%m%d%H.log`.
 
    The time format used as part of the file name. The following characters are replaced with actual values when the file is created:
    
    * %Y: year including the century (at least 4 digits)
    * %m: month of the year (01..12)
    * %d: Day of the month (01..31)
    * %H: Hour of the day, 24-hour clock (00..23)
    * %M: Minute of the hour (00..59)
    * %S: Second of the minute (00..60)

* time\_slice\_format (obsolete)

    This option is provided just for compatibility with `out_file`. 
    Use time format in `path` parameter instead.

* format

    The format of the file content. The default is `out_file`.

    Please refer [out_file#format](http://docs.fluentd.org/articles/out_file#format).

* time\_format

    The format of the time written in files. The default format is ISO-8601.

* utc

    Uses UTC for path formatting. The default format is localtime.

* compress

    Compresses files using gzip. No compression is performed by default.

* time\_slice\_wait (obsolete)

    This option is provided just for compatibility with `out_file`.
    Use `compress_wait` instead.

* compress\_wait

    The amount of time Fluentd will wait for old logs to compress. This is used to account for delays in logs arriving to your Fluentd node. The default wait time is 10 minutes (‘10m’), where Fluentd will wait until 10 minutes past the hour for any logs that occured within the past hour.

    For example, when splitting files on an hourly basis, a log recorded at 1:59 but arriving at the Fluentd node between 2:00 and 2:10 will be uploaded together with all the other logs from 1:00 to 1:59 in one transaction, avoiding extra overhead. Larger values can be set as needed.

* symlink\_path

    Create symlink to the newest file created.. No symlink is created by default. This is useful for tailing file content to check logs.

## Differences

Notable differences with `out_file`:

* No buffer file is generated.
* `append true|false` option was removed. Always `append true`. 
* Filename is expanded using the current time, rather than the time in a chunk. 

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

