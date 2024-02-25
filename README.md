# pgschema-helper

Parse the full schema file produced by `pgdump --schema-only` and break this file into individual components such
as table, view, function, etc and save them into a designated output directory.

## Install

```
npm i pgschema-helper
```

## Usage

```typescript
const writer = new SchemaWritter('./output');
const lines = readLineByLine('./input/schema.sql');
for await (const line of lines) {
    writer.writeOutput(line);
}
writer.close();
```
