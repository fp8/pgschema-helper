import * as fs from 'fs';
import * as readline from 'readline';
import * as nodePath from 'path';

export type TFilesInDirectoryEntry = {type: 'file' | 'dir', filePath: string, stat: fs.Stats};

/**
 * Return a path as a stream
 *
 * @param filepath 
 * @returns 
 */
export function loadFileAsStream(filepath: string): fs.ReadStream {
    if (!fs.existsSync(filepath)) {
        throw new Error(`File does not exist: ${filepath}`);
    }
    return fs.createReadStream(filepath, {encoding: 'utf8'});
}

/**
 * Read an input line by line.  If input is a string, assume that it's a file path and load the file as a stream.
 * 
 * @param input 
 * @returns 
 */
export function readLineByLine(input: string | fs.ReadStream): readline.Interface {
    let stream: fs.ReadStream;

    if (typeof input === 'string') {
        stream = loadFileAsStream(input);
    } else {
        stream = input;
    }

    return readline.createInterface({
        input: stream,
        crlfDelay: Infinity
    });
}

/**
 * Recurve through a directory and recursively return files and directories.
 * If symlink is encountered, it's treated as a file.
 * 
 * Usage:
 * 
 * for (const {type, filePath, stat} of filesInDirectory('./path/to/dir') {
 *     // Do something with the file path
 * }
 * 
 * @param dirname 
 */
export function* filesInDirectory(dirname: string, filesOnly = false): Iterable<TFilesInDirectoryEntry> {
    const files = fs.readdirSync(dirname);
    for (const name of files) {
        var filePath = nodePath.join(dirname, name);
        var stat = fs.statSync(filePath);
        if (stat.isFile() || stat.isSymbolicLink()) {
            yield { type: 'file', filePath, stat};
        } else if (stat.isDirectory()) {
            if (!filesOnly) {
                yield { type: 'dir', filePath, stat};
            }
            for (const entry of filesInDirectory(filePath, filesOnly)) {
                yield entry;
            }
        }
    }
}
