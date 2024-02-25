# pgschema-helper

Parse the full schema file produced by `pgdump --schema-only` and break this file into individual components such
as table, view, function, etc and save them into a designated output directory.

## Install

```
npm i pgschema-helper
```

## Usage

### Library

The [SchemaWritter](https://fp8.github.io/pgschema-helper/classes/SchemaWritter.html) is the class that will parse
the schema sql line by line and generate the output to the specified directory on the fly.  To help processing of
the incoming schema sql line by line, use [readLineByLine](https://fp8.github.io/pgschema-helper/functions/readLineByLine.html)
that is designed for this purpose.

```typescript
const writer = new SchemaWritter('./output');
const lines = readLineByLine('./input/schema.sql');
for await (const line of lines) {
    writer.writeOutput(line);
}
writer.close();
```

### CLI

```
Usage:
    pgschema-generator [options] <schema-file>

Read from STDIN:
    * pass '-' as <schema-file> 

Options:
    --output, -o    Output directory [default: ./output]
    --help          Show help
```

## Documentation

* [pgschema-helper](https://fp8.github.io/pgschema-helper/)
