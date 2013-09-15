# -*- coding: utf-8 -*-
#
# Copyright (C) 2012-2013  Haruka Yoshihara <yoshihara@clear-code.com>
# Copyright (C) 2012-2013  Kouhei Sutou <kou@clear-code.com>
# Copyright (C) 2005-2009 Masao Mutoh
# Copyright (C) 2005,2006 speakillof
#
# License: Ruby's or LGPL
#
# This library is free software: you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

require "optparse"
require "text"
require "gettext"
require "gettext/po_parser"
require "gettext/po"

module GetText
  module Tools
    class MsgMerge
      class Merger #:nodoc:
        # Merge the reference with the definition: take the #. and
        #  #: comments from the reference, take the # comments from
        # the definition, take the msgstr from the definition.  Add
        # this merged entry to the output message list.

        POT_DATE_EXTRACT_RE = /POT-Creation-Date:\s*(.*)?\s*$/
        POT_DATE_RE = /POT-Creation-Date:.*?$/

        def merge(definition, reference)
          result = GetText::PO.new

          translated_entries = definition.reject do |entry|
            entry.msgstr.nil?
          end

          reference.each do |entry|
            msgid = entry.msgid
            msgctxt = entry.msgctxt
            id = [msgctxt, msgid]

            if definition.has_key?(*id)
              result[*id] = merge_entry(definition[*id], entry)
              next
            end

            if msgctxt.nil?
              same_msgid_entry = find_by_msgid(translated_entries, msgid)
              if not same_msgid_entry.nil? and not same_msgid_entry.msgctxt.nil?
                result[nil, msgid] = merge_fuzzy_entry(same_msgid_entry, entry)
                next
              end
            end

            fuzzy_entry = find_fuzzy_entry(translated_entries, msgid, msgctxt)
            unless fuzzy_entry.nil?
              result[*id] = merge_fuzzy_entry(fuzzy_entry, entry)
              next
            end

            result[*id] = entry
          end

          add_obsolete_entry(result, translated_entries)
          result
        end

        def merge_entry(definition_entry, reference_entry)
          if definition_entry.msgid.empty? and definition_entry.msgctxt.nil?
            new_header = merge_header(definition_entry, reference_entry)
            return new_header
          end

          if definition_entry.flag == "fuzzy"
            entry = definition_entry
            entry.flag = "fuzzy"
            return entry
          end

          entry = reference_entry
          entry.translator_comment = definition_entry.translator_comment
          entry.previous = nil

          unless definition_entry.msgid_plural == reference_entry.msgid_plural
            entry.flag = "fuzzy"
          end

          entry.msgstr = definition_entry.msgstr
          entry
        end

        def merge_header(old_header, new_header)
          header = old_header
          if POT_DATE_EXTRACT_RE =~ new_header.msgstr
            create_date = $1
            pot_creation_date = "POT-Creation-Date: #{create_date}"
            header.msgstr = header.msgstr.gsub(POT_DATE_RE, pot_creation_date)
          end
          header.flag = nil
          header
        end

        def find_by_msgid(entries, msgid)
          same_msgid_entries = entries.find_all do |entry|
            entry.msgid == msgid
          end
          same_msgid_entries = same_msgid_entries.sort_by do |entry|
            entry.msgctxt
          end
          same_msgid_entries.first
        end

        def merge_fuzzy_entry(fuzzy_entry, entry)
          merged_entry = merge_entry(fuzzy_entry, entry)
          merged_entry.flag = "fuzzy"
          merged_entry
        end

        MAX_FUZZY_DISTANCE = 0.5 # XXX: make sure that its value is proper.

        def find_fuzzy_entry(definition, msgid, msgctxt)
          return nil if msgid == :last
          min_distance_entry = nil
          min_distance = MAX_FUZZY_DISTANCE

          same_msgctxt_entries = definition.find_all do |entry|
            entry.msgctxt == msgctxt and not entry.msgid == :last
          end
          same_msgctxt_entries.each do |entry|
            distance = normalize_distance(entry.msgid, msgid)
            if min_distance > distance
              min_distance = distance
              min_distance_entry = entry
            end
          end

          min_distance_entry
        end

        def normalize_distance(source, destination)
          max_size = [source.size, destination.size].max

          return 0.0 if max_size.zero?
          Text::Levenshtein.distance(source, destination) / max_size.to_f
        end

        def add_obsolete_entry(result, definition)
          obsolete_entry = generate_obsolete_entry(result, definition)
          unless obsolete_entry.nil?
            result[:last] = obsolete_entry
          end
          result
        end

        def generate_obsolete_entry(result, definition)
          obsolete_entry = nil

          obsolete_entries = extract_obsolete_entries(result, definition)
          unless obsolete_entries.empty?
            obsolete_comment = []

            obsolete_entries.each do |entry|
              obsolete_comment << entry.to_s
            end
            obsolete_entry = POEntry.new(:normal)
            obsolete_entry.msgid = :last
            obsolete_entry.comment = obsolete_comment.join("\n")
          end
          obsolete_entry
        end

        def extract_obsolete_entries(result, definition)
          obsolete_entries = []
          definition.each do |entry|
            id = [entry.msgctxt, entry.msgid]
            if not result.has_key?(*id) and not entry.msgid == :last
              obsolete_entries << entry
            end
          end
          obsolete_entries
        end
      end

      # @private
      class Config
        include GetText

        bindtextdomain("gettext")

        attr_accessor :definition_po, :reference_pot
        attr_accessor :output, :fuzzy, :update

        # update mode options
        attr_accessor :backup, :suffix

        # The result is written back to def.po.
        #       --backup=CONTROL        make a backup of def.po
        #       --suffix=SUFFIX         override the usual backup suffix
        # The version control method may be selected
        # via the --backup option or through
        # the VERSION_CONTROL environment variable.  Here are the values:
        #   none, off       never make backups (even if --backup is given)
        #   numbered, t     make numbered backups
        #   existing, nil   numbered if numbered backups exist, simple otherwise
        #   simple, never   always make simple backups
        # The backup suffix is `~', unless set with --suffix or
        # the SIMPLE_BACKUP_SUFFIX environment variable.

        def initialize
          @definition_po = nil
          @reference_po = nil
          @output = nil
          @fuzzy = nil
          @update = nil
          @backup = ENV["VERSION_CONTROL"]
          @suffix = ENV["SIMPLE_BACKUP_SUFFIX"] || "~"
          @input_dirs = ["."]
        end

        def parse(command_line)
          parser = create_option_parser
          rest = parser.parse(command_line)

          if rest.size != 2
            puts(parser.help)
            exit(false)
          end

          @definition_po, @reference_pot = rest
        end

        private
        def create_option_parser
          parser = OptionParser.new
          parser.banner =
            _("Usage: %s [OPTIONS] definition.po reference.pot") % $0
          #parser.summary_width = 80
          parser.separator("")
          description = _("Merges two Uniforum style .po files together. " +
                            "The definition.po file is an existing PO file " +
                            "with translations. The reference.pot file is " +
                            "the last created PO file with up-to-date source " +
                            "references. The reference.pot is generally " +
                            "created by rxgettext.")
          parser.separator(description)
          parser.separator("")
          parser.separator(_("Specific options:"))

          parser.on("-o", "--output=FILE",
                    _("Write output to specified file")) do |output|
            @output = output
          end

          #parser.on("-F", "--fuzzy-matching")

          parser.on("-h", "--help", _("Display this help and exit")) do
            puts(parser.help)
            exit(true)
          end

          parser.on_tail("--version",
                         _("Display version information and exit")) do
            puts(GetText::VERSION)
            exit(true)
          end

          parser
        end
      end

      class << self
        # (see #run)
        #
        # This method is provided just for convenience. It equals to
        # `new.run(*command_line)`.
        def run(*command_line)
          new.run(*command_line)
        end
      end

      # Merge a po-file inluding translated messages and a new pot-file.
      #
      # @param [Array<String>] command_line
      #   command line arguments for rmsgmerge.
      # @return [void]
      def run(*command_line)
        config = Config.new
        config.parse(command_line)

        parser = POParser.new
        parser.ignore_fuzzy = false
        definition_po = PO.new
        reference_pot = PO.new
        parser.parse_file(config.definition_po, definition_po)
        parser.parse_file(config.reference_pot, reference_pot)

        merger = Merger.new
        result = merger.merge(definition_po, reference_pot)
        p result if $DEBUG
        print result.generate_po if $DEBUG

        if config.output.is_a?(String)
          File.open(File.expand_path(config.output), "w+") do |file|
            file.write(result.to_s)
          end
        else
          puts(result.to_s)
        end
      end
    end
  end
end
