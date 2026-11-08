# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "afterburner"
require "minitest/autorun"
require "tmpdir"

# A cut-down NetscriptDefinitions.d.ts in the real file's format.
FIXTURE_DEFINITIONS = <<~TS
  interface Server {
    hostname: string;
    moneyMax?: number;
    hasAdminRights: boolean;
  }

  interface Hacknet {
    /**
     * Number of nodes.
     * @remarks
     * RAM cost: 0.5 GB
     */
    numNodes(): number;
  }

  interface UserInterface {
    /**
     * @remarks
     * RAM cost: 0 GB
     */
    openTail(fn?: string): void;
  }

  interface Base {
    /**
     * @remarks
     * RAM cost: 1 GB
     */
    inherited(): number;
  }

  export interface Child extends Base {
    /**
     * @remarks
     * RAM cost: 2 GB
     */
    own(): number;
  }

  export interface NS {
    readonly hacknet: Hacknet;
    readonly ui: UserInterface;
    readonly child: Child;
    readonly args: ScriptArg[];
    readonly pid: number;
    readonly heart: {
      /**
       * RAM cost: 0 GB
       */
      break(): number;
    };

    /**
     * Steal money.
     * @remarks
     * RAM cost: 0.1 GB
     */
    hack(host?: string, opts?: BasicHGWOptions): Promise<number>;

    /**
     * @remarks
     * RAM cost: 0.1 GB
     */
    getServerMaxMoney(host: string): number;

    /**
     * @remarks
     * RAM cost: 0.05 GB
     */
    hasRootAccess(host: string): boolean;

    /**
     * @remarks
     * RAM cost: 0.05 GB
     */
    nuke(host: string): boolean;

    /**
     * @remarks
     * RAM cost: 0.1 GB
     */
    isRunning(
      script: string,
      host?: string,
    ): boolean;

    /**
     * @remarks
     * RAM cost: 2 GB
     */
    getServer(host?: string): Server;

    /**
     * Exists to collide with getServer's short alias.
     * @remarks
     * RAM cost: 0.25 GB
     */
    server(): number;

    /**
     * @remarks
     * RAM cost: 0.05 GB
     */
    getHackingLevel(): number;

    /**
     * @remarks
     * RAM cost: 0 GB
     */
    tprint(...args: any[]): void;

    /**
     * @remarks
     * RAM cost: 0 GB
     */
    print(...args: any[]): void;

    /**
     * @remarks
     * RAM cost: 0 GB
     */
    sleep(millis: number): Promise<true>;

    /**
     * @remarks
     * RAM cost: 0 GB
     */
    atExit(f: () => void, id?: string): void;
  }
TS

module FixtureApi
  def api = @api ||= Afterburner::Api.new(FIXTURE_DEFINITIONS)

  def with_definitions
    Dir.mktmpdir do |dir|
      path = File.join(dir, "NetscriptDefinitions.d.ts")
      File.write(path, FIXTURE_DEFINITIONS)
      yield path, dir
    end
  end
end

# Stands in for GameLink in unit tests: records what would be sent.
class RecordingLink
  attr_reader :pushed, :deleted
  attr_accessor :files

  def initialize(files: [])
    @pushed = {}
    @deleted = []
    @files = files
  end

  def push_file(name, content) = @pushed[name] = content
  def delete_file(name) = @deleted << name
  def all_files = @files
end

def quiet_log(io = StringIO.new) = Logger.new(io)
