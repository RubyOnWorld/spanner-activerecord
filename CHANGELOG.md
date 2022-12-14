# Changelog

### 1.2.2 (2022-08-29)

#### Documentation

* add ActiveRecord 7 as a supported version to the README ([#189](https://github.com/googleapis/ruby-spanner-activerecord/issues/189)) 
* update limitation on interleaved tables and default column values ([#190](https://github.com/googleapis/ruby-spanner-activerecord/issues/190)) 

### 1.2.1 (2022-08-28)

#### Bug Fixes

* Corrected the namespace for the transaction selector class ([#187](https://github.com/googleapis/ruby-spanner-activerecord/issues/187)) 

### 1.2.0 (2022-08-03)

#### Features

* support composite primary keys for interleaved tables ([#175](https://github.com/googleapis/ruby-spanner-activerecord/issues/175)) 

### 1.1.0 (2022-06-24)

#### Features

* Support insert_all and upsert_all with DML and mutations

### 1.0.1 (2022-04-21)

#### Bug Fixes

* ActiveRecord::Type::Spanner::Array does not use element type

#### Documentation

* add limitation of interleaved tables
* fix a couple of minor formatting issues

### 1.0.0 (2021-12-07)

* GA release

### 0.7.1 (2021-11-21)

#### Performance Improvements

* inline BeginTransaction with first statement in the transaction

### 0.7.0 (2021-10-03)

#### Features

* add support for query hints

### 0.6.0 (2021-09-09)

#### Features

* support JSON data type
* support single stale reads
* support stale reads in read-only transactions

### 0.5.0 (2021-08-31)

#### Features

* Add support for NUMERIC type
* Add support for ARRAY data type
* google-cloud-spanner version upgraded to 2.2
* retry session not found
* support and test multiple ActiveRecord versions
* support DDL batches on connection
* support generated columns
* support interleaved indexes + test other index features
* support optimistic locking
* support PDML transactions
* support prepared statements and query cache
* support read only transactions
* support setting attributes to commit timestamp

#### Performance Improvements

* add benchmarks
