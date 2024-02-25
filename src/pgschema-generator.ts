import * as fs from 'fs';
import * as readline from 'readline';

import { readLineByLine } from "./helper";
import { SchemaWritter } from "./services";

/**
 * Assume that first argument is the sql file to read.  If file argument passed, assume that it's a file path
 * and ensure that file exists before contiuining.
 *
 * @returns 
 */
function readInputArgs(): string | undefined {
    let filePath: string | undefined = undefined;
    if (process.argv.length > 2) {
        filePath = process.argv[2];
        if (!fs.existsSync(filePath) || !fs.lstatSync(filePath).isFile()) {
            throw new Error(`File does not exist: ${filePath}`);
        }
    }
    return filePath;
}

/**
 * Main function to read schema and generate files in a ./output directory.
 */
async function main() {
    const inputFile = readInputArgs();

    let lines: readline.Interface;
    if (inputFile) {
        lines = readLineByLine(inputFile);
    } else {
        lines = readline.createInterface({
            input: process.stdin,
            crlfDelay: Infinity
        });
    }

    const writer = new SchemaWritter('./output');
    for await (const line of lines) {
        writer.writeOutput(line);
    }
    writer.close();
}

// Execute the program
main().catch(console.error);
