import {expect, loadDataFile, loadDataFileAsStream} from '../../testlib';

import { EnumSchemaObjectType, ParsedSchemaObject } from '../../../src/models';
import {
    parseSchemaObjectFromLine,
    getObjectForPathFromSchemaObject, amendParsedObject,
    TTableOrView
} from '../../../src/services/schema-writter';


interface IObjectNameConfig {
    input: string;
    expected: ParsedSchemaObject;
    TODO?: string;
}

interface IObjectNameConfigs {
    data: IObjectNameConfig[];
}

interface INameAndType {
    input: string;
    exepected: {name: string, type: string};
}

interface INameAndTypes {
    data: IObjectNameConfig[];
}




describe('services.schema-writter.funcs', () => {
    it('parseSchemaObjectFromLine', () => {
        const config: IObjectNameConfigs = loadDataFile('object-names.json');

        for (const entry of config.data) {
            const parsed = parseSchemaObjectFromLine(entry.input);
            if (parsed === undefined) {
                expect(entry.expected).to.be.null;
            } else {
                expect(parsed).to.deep.equal(entry.expected, `Expect ${JSON.stringify(parsed)} to match`);
            }
            
        }
    });

    it('getTypeAndNameFromSchemaObject', () => {
        const config: INameAndTypes = loadDataFile('type-name.json');
        const tableOrView: TTableOrView = {};

        for (const entry of config.data) {
            const obj = parseSchemaObjectFromLine(entry.input);
            expect(obj).to.not.be.undefined;


            if (obj!.type === EnumSchemaObjectType.table || obj!.type === EnumSchemaObjectType.view) {
                tableOrView[obj!.name] = obj!.type;
            }

            const parsed = getObjectForPathFromSchemaObject(obj!, tableOrView);
            expect(parsed).to.deep.equal(entry.expected, `Expect ${JSON.stringify(parsed)} to match`);
        }
    });

    it('amendParsedObject - index', () => {
        const parsed = ParsedSchemaObject.create({
            type: EnumSchemaObjectType.index,
            name: "idx_position_portfolio_position_type",
            schema: "public",
            owner: "exa_db"
        });
        const line = 'CREATE INDEX idx_position_portfolio_position_type ON public."position" USING btree (rpt_date, portfolio_key, position_type, instrument_key);';

        amendParsedObject(line, parsed);
        expect(parsed.table).to.equal('position');
    });


});
