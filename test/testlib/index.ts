import 'reflect-metadata'; // required by @fp8/simple-config

// Configure Logger
import {LogLevel, SimpleTextDestination} from 'jlog-facade';
SimpleTextDestination.use(LogLevel.DEBUG);

// tslint:disable-next-line
import 'mocha';

import chai = require('chai');
import sinon = require('sinon');
import sinonChai = require('sinon-chai');
import chaiAsPromised = require('chai-as-promised');

chai.use(chaiAsPromised);
chai.use(sinonChai);

export const {expect} = chai;
export {sinon, chai};

// Export
export * from './data';
