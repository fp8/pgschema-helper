import { expect, getDataFilename } from '../../testlib';

import { SchemaWritter } from '../../../src/services/schema-writter';
import { readLineByLine, filesInDirectory } from '../../../src/helper/file-io';



describe('services.schema-writter.output', () => {
    it('SchemaWritter', async () => {
        const expected: Set<string> = new Set();
        for await (const line of readLineByLine(getDataFilename('output-files.txt'))) {
            expected.add(line);
        }

        // Write sql to the output directory
        const writer = new SchemaWritter('./output');
        const lines = readLineByLine(getDataFilename('schema.sql'));
        for await (const line of lines) {
            writer.writeOutput(line);
        }

        // Source the output
        const result: string[] = [];
        for await (const {filePath} of filesInDirectory('./output', true)) {
            expect(expected.has(filePath), `File ${filePath} not expected.`).to.be.true;
            result.push(filePath);
        }

        // Check output
        expect(result).to.have.members(Array.from(expected));
    });
});