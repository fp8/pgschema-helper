import {expect, getDataFilename} from '../testlib';

import * as os from 'os';
import * as fs from 'fs';
import * as readline from 'readline';

import { loadFileAsStream, readLineByLine, filesInDirectory, TFilesInDirectoryEntry } from '../../src/helper/file-io';



const contentOfSimpleTextFile = `This is simple.txt with content of qiPBpFLHdy.${os.EOL}Line 2 of MsaBm7hBQI.${os.EOL}`;

describe('helper.file-io', () => {

    describe('loadFileAsStream', () => {
        it('should return a ReadStream', () => {
            const filepath = getDataFilename('helper/simple.txt');
            const stream = loadFileAsStream(filepath);
            expect(stream).to.be.an.instanceOf(fs.ReadStream);
        });
    
        it('should throw an error if the file does not exist', () => {
            const filepath = getDataFilename('nonexistent.txt');
            expect(() => loadFileAsStream(filepath)).to.throw();
        });
    
        it('should read the correct content from the file', (done) => {
            const filepath = getDataFilename('helper/simple.txt');
            const stream = loadFileAsStream(filepath);
            let content = '';
            stream.on('data', (chunk) => {
                content += chunk;
            });
            stream.on('end', () => {
                expect(content).to.equal(contentOfSimpleTextFile);
                done();
            });
        });
    });

    describe('readLineByLine', () => {
        it('should return a readline.Interface when given a string', () => {
            const filepath = getDataFilename('helper/simple.txt');
            const rl = readLineByLine(filepath);
            expect(rl).to.be.an.instanceOf(readline.Interface);
        });
    
        it('should return a readline.Interface when given a ReadStream', () => {
            const filepath = getDataFilename('helper/simple.txt');
            const stream = loadFileAsStream(filepath);
            const rl = readLineByLine(stream);
            expect(rl).to.be.an.instanceOf(readline.Interface);
        });
    
        it('should read the correct content from the file', (done) => {
            const filepath = getDataFilename('helper/simple.txt');
            const rl = readLineByLine(filepath);
            const expected = contentOfSimpleTextFile.split(os.EOL).join('');
            let content = '';
            rl.on('line', (line) => {
                content += line;
            });
            rl.on('close', () => {
                expect(content).to.equal(expected);
                done();
            });
        });
    
        it('should throw an error if the file does not exist', () => {
            const filepath = getDataFilename('nonexistent.txt');
            expect(() => readLineByLine(filepath)).to.throw();
        });
    });

    describe('filesInDirectory', () => {
        const dirname = 'test/data';
        const dirs = [
            'test/data/helper',
        ];
        const files = [
            'test/data/object-names.json',
            'test/data/schema.sql',
            'test/data/output-files.txt',
            'test/data/type-name.json',
            'test/data/helper/simple.txt'
        ];



        it('should yield all files and directories in the given directory', () => {
            const expected: TFilesInDirectoryEntry[] = [];
            files.forEach((filePath) => {
                expected.push({ type: 'file', filePath, stat: fs.statSync(filePath)});
            });
            dirs.forEach((dirPath) => {
                expected.push({ type: 'dir', filePath: dirPath, stat: fs.statSync(dirPath)});
            });

            const entries = [...filesInDirectory(dirname)];
            expect(entries).to.have.lengthOf(6);

            // Array of objects needs to be sorted before comparing
            const compare = (a: TFilesInDirectoryEntry, b: TFilesInDirectoryEntry) => (a.filePath > b.filePath) ? 1 : ((b.filePath > a.filePath) ? -1 : 0);
            expected.sort(compare);
            entries.sort(compare);

            expect(entries).to.eql(expected);
        });
    
        it('should yield only files when filesOnly is true', () => {
            const expected: {type: 'file' | 'dir', filePath: string, stat: fs.Stats}[] = [];
            files.forEach((filePath) => {
                expected.push({ type: 'file', filePath, stat: fs.statSync(filePath)});
            });

            const entries = [...filesInDirectory(dirname, true)];
            expect(entries).to.have.lengthOf(5);
            expect(entries).to.deep.include.members(expected);
        });
    
        it('should throw an error if the directory does not exist', () => {
            const dirname = getDataFilename('test/nonexistentDir');
            expect(() => [...filesInDirectory(dirname)]).to.throw();
        });
    });
});


