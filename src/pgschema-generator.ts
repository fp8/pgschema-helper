import * as fs from 'fs';
import * as readline from 'readline';
import * as getopts from 'getopts';

import { readLineByLine } from "./helper";
import { SchemaWritter } from "./services";

const REGEX_LEADING_SPACE = /^\s$/m;

enum EnumRunMode {
    FILE,
    STDIN
}

interface IRunArgs {
    mode: EnumRunMode;
    inputSchema: string | undefined;
    outputDir: string;
}

function displayHelpMessageAndExit(exitCode = 0) {
    const message = `
Usage:
    pgschema-generator [options] <schema-file>

Read from STDIN:
    * pass '-' as <schema-file> 

Options:
    --output, -o    Output directory [default: ./output]
    --help          Show help
    `;

    console.log(message.replace(REGEX_LEADING_SPACE, ''));
    process.exit(exitCode);
}


/**
 * Assume that first argument is the sql file to read.  If file argument passed, assume that it's a file path
 * and ensure that file exists before contiuining.
 *
 * @returns 
 */
function readRunArgs(): IRunArgs {
    const result: IRunArgs = {
        mode: EnumRunMode.FILE,
        inputSchema: undefined,
        outputDir: './output'
    }

    const options = getopts(process.argv.slice(2), {
        string: ['output'],
        boolean: ['help'],
        alias: {
          output: ["o"]
        }
    });

    // If help is passed, show help message
    if (options.help) {
        displayHelpMessageAndExit(0);
    }

    // A <schema-file> must be passed or missing parameters error show be displayed
    if (options._.length) {
        const filePath = options._[0];
        if (filePath === '-') {
            result.mode = EnumRunMode.STDIN;
        } else {
            result.mode = EnumRunMode.FILE;
            result.inputSchema = filePath;

            // Make sure that file exists
            if (!fs.existsSync(filePath) || !fs.lstatSync(filePath).isFile()) {
                console.error(`ERROR: File does not exist: ${filePath}`);
                displayHelpMessageAndExit(1);
            }
        }
    } else {
        console.error('ERROR: missing required <schema-file> parameter');
        displayHelpMessageAndExit(1);
    }

    // Set output directory
    if (options.output) {
        result.outputDir = options.output;
    }

    console.log(result);
    return result;
}

/**
 * Main function to read schema and generate files in a ./output directory.
 */
async function main() {
    const args = readRunArgs();

    let lines: readline.Interface;
    switch (args.mode) {
        case EnumRunMode.FILE:
            if (!args.inputSchema) {
                throw new Error('inputSchema is not defined');
            }
            lines = readLineByLine(args.inputSchema);
            break;
        case EnumRunMode.STDIN:
            lines = readline.createInterface({
                input: process.stdin,
                crlfDelay: Infinity
            });
            break;
    }

    const writer = new SchemaWritter(args.outputDir);
    try {
        for await (const line of lines) {
            writer.writeOutput(line);
        }
    } catch (error) {
        throw error;
    } finally {
        writer.close();
    }
}

// Execute the program
main().catch((error) => {
    console.error(`Error: ${error.message}`);
    process.exit(1);
});