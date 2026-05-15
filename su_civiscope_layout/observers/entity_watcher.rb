# 编码：UTF-8
module CiviscopeLayout
  module Core

    class EntityWatcher < Sketchup::EntityObserver
      def onElementModified(*args)
        entity = args.last
        return if CiviscopeLayout::Core.skip_recalc
        CiviscopeLayout::Core.schedule_auto_recalc(entity)
      end

      def onTransformationChanged(*args)
        entity = args.last
        return if CiviscopeLayout::Core.skip_recalc
        CiviscopeLayout::Core.schedule_auto_recalc(entity)
      end

      def onChangeEntity(*args)
        entity = args.last
        return if CiviscopeLayout::Core.skip_recalc
        CiviscopeLayout::Core.schedule_auto_recalc(entity)
      end
    end

    class BimEntitiesWatcher < Sketchup::EntitiesObserver
      def initialize(definition)
        @definition = definition
      end

      def onElementAdded(entities, entity)
        return if CiviscopeLayout::Core.skip_recalc
        return if entity.is_a?(Sketchup::Group) && entity.get_attribute("civiscope", "is_roof_structure")
        trigger_update
      end

      def onElementModified(entities, entity)
        return if CiviscopeLayout::Core.skip_recalc
        return if entity.is_a?(Sketchup::Group) && entity.get_attribute("civiscope", "is_roof_structure")
        trigger_update
      end

      def onElementRemoved(entities, entity_id)
        return if CiviscopeLayout::Core.skip_recalc
        trigger_update
      end

      def trigger_update
        @definition.instances.each do |inst|
          CiviscopeLayout::Core.schedule_auto_recalc(inst)
        end
      end
    end

    # 修改几何体的工具 ID，使用时抑制自动重算
    MODIFICATION_TOOL_IDS = [21023, 21236, 21048, 21056, 21101].freeze  # Scale(21023/21236), Move, Rotate, Push/Pull

    class CiviToolObserver < Sketchup::ToolsObserver
      def onActiveToolChanged(tools, tool_name, tool_id)
        unless MODIFICATION_TOOL_IDS.include?(tool_id)
          CiviscopeLayout::Core.flush_pending_recalc
        end
      end
    end

    def self.schedule_auto_recalc(entity)
      eid = get_short_id(entity) rescue '?'
      puts "[DEBUG-FL] schedule_auto_recalc entity=#{eid} valid=#{entity.valid?} skip_recalc=#{CiviscopeLayout::Core.skip_recalc}"
      return unless entity.valid?
      return if CiviscopeLayout::Core.skip_recalc

      begin
        tool_id = Sketchup.active_model.tools.active_tool_id
        tool_name = Sketchup.active_model.tools.active_tool_name rescue '?'
        puts "[DEBUG-FL] schedule_auto_recalc tool=#{tool_name}(#{tool_id}) in_mod_list=#{MODIFICATION_TOOL_IDS.include?(tool_id)}"
        if MODIFICATION_TOOL_IDS.include?(tool_id)
          @pending_recalc_entity = entity
          puts "[DEBUG-FL] schedule_auto_recalc DEFERRED — pending entity stored, safety timer 1.5s"
          # 安全定时器：若 onTransactionCommit 未触发，1.5s 后强制 flush
          UI.stop_timer(@safety_timer_id) if @safety_timer_id
          @safety_timer_id = UI.start_timer(1.5, false) do
            @safety_timer_id = nil
            puts "[DEBUG-FL] SAFETY-TIMER fired"
            self.flush_pending_recalc
          end
          return
        end
      rescue => ex
        puts "[DEBUG-FL] schedule_auto_recalc tool detect ERROR: #{ex.message}"
      end

      @pending_recalc_entity = nil
      UI.stop_timer(@timer_id) if @timer_id
      UI.stop_timer(@safety_timer_id) if @safety_timer_id
      puts "[DEBUG-FL] schedule_auto_recalc NORMAL timer 0.3s"
      @timer_id = UI.start_timer(0.3, false) do
        @timer_id = nil
        puts "[DEBUG-FL] NORMAL-TIMER fired → auto_recalculate"
        self.auto_recalculate(entity)
      end
    end

    def self.flush_pending_recalc
      entity = @pending_recalc_entity
      @pending_recalc_entity = nil
      eid = get_short_id(entity) rescue 'nil'
      e_valid = entity && entity.valid? rescue false
      puts "[DEBUG-FL] flush_pending_recalc entity=#{eid} valid=#{e_valid}"
      UI.stop_timer(@safety_timer_id) if @safety_timer_id
      @safety_timer_id = nil
      return unless e_valid
      UI.stop_timer(@timer_id) if @timer_id
      puts "[DEBUG-FL] flush_pending_recalc starting 0.1s timer → auto_recalculate"
      @timer_id = UI.start_timer(0.1, false) do
        @timer_id = nil
        puts "[DEBUG-FL] FLUSH-TIMER fired → auto_recalculate"
        self.auto_recalculate(entity)
      end
    end

    def self.cancel_pending_recalc
      UI.stop_timer(@timer_id) if @timer_id
      @timer_id = nil
      UI.stop_timer(@safety_timer_id) if @safety_timer_id
      @safety_timer_id = nil
      @pending_recalc_entity = nil
    end

    # 附加实体观察者（委托给 ObserverManager）
    def self.attach_observers(entity)
      ObserverManager.attach_entity_observers(entity)
    end

  end
end
