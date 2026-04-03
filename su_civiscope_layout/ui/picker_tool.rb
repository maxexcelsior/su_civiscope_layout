# 编码：UTF-8
module CiviscopeLayout
  module Core
    
    class FunctionPickerTool
      def initialize(mode = 'bldg')
        @mode = mode 
        @state = :pick
        @picked_data = nil
        
        icon_dir = File.join(__dir__, '..', 'icon')
        pick_svg = File.join(icon_dir, 'picker.svg')
        paint_svg = File.join(icon_dir, 'paint.svg')
        
        # Use SVG if available, fallback to default cursors
        @cursor_pick = File.exist?(pick_svg) ? UI.create_cursor(pick_svg, 4, 26) : 632
        @cursor_paint = File.exist?(paint_svg) ? UI.create_cursor(paint_svg, 4, 26) : 636
      end

      def onSetCursor
        cursor_id = @state == :pick ? @cursor_pick : @cursor_paint
        UI.set_cursor(cursor_id) if cursor_id != 0
      end

      def activate
        update_status
      end

      def resume(view)
        update_status
      end

      def update_status
        mode_text = @mode == 'bldg' ? "建筑" : "用地"
        val = @state == :pick ? "[吸取模式]" : "[涂刷模式]: #{@picked_data[:func]}"
        Sketchup.status_text = "#{mode_text}属性刷 | #{val} | 按ESC退出"
      end

      def onMouseMove(flags, x, y, view)
        msg = if @state == :pick
                @mode == 'bldg' ? "点击吸取建筑功能" : "点击吸取地块属性"
              else
                "赋予: #{@picked_data[:func]} (ESC取消)"
              end
        view.tooltip = msg
        view.invalidate
      end

      def onLButtonDown(flags, x, y, view)
        ph = view.pick_helper
        ph.do_pick(x, y)
        target = ph.best_picked
        
        unless target && (target.is_a?(Sketchup::Group) || target.is_a?(Sketchup::ComponentInstance))
          if ph.count > 0
            path = ph.path_at(0)
            target = path.reverse.find { |e| e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance) }
          end
        end
        return unless target

        model = Sketchup.active_model

        if @state == :pick
          if target.get_attribute("dynamic_attributes", "#{@mode}_func")
            @picked_data = {
              func: target.get_attribute("dynamic_attributes", "#{@mode}_func"),
              no: target.get_attribute("dynamic_attributes", "#{@mode}_no"),
              h: target.get_attribute("dynamic_attributes", "floor_height"),
              hl: target.get_attribute("dynamic_attributes", "height_limit"),
              type: target.get_attribute("dynamic_attributes", "bldg_type"),
              site_type: target.get_attribute("dynamic_attributes", "site_type")
            }
            @state = :paint
            update_status
            view.refresh
          else
            UI.beep
          end

        elsif @state == :paint
          if target.get_attribute("dynamic_attributes", "#{@mode}_func")
            model.start_operation("属性刷:赋予#{@mode == 'bldg' ? '建筑' : '地块'}功能", true)
            target.set_attribute("dynamic_attributes", "#{@mode}_func", @picked_data[:func])
            target.set_attribute("dynamic_attributes", "floor_height", @picked_data[:h]) if @mode == 'bldg'
            target.set_attribute("dynamic_attributes", "bldg_type", @picked_data[:type]) if @mode == 'bldg'
            target.set_attribute("dynamic_attributes", "site_type", @picked_data[:site_type]) if @mode == 'site'
            target.set_attribute("dynamic_attributes", "height_limit", @picked_data[:hl]) if @mode == 'site'
            
            CiviscopeLayout::Core.auto_recalculate(target, true, true)
            model.commit_operation
            
            CiviscopeLayout::Core.refresh_stats_ui(model.selection) if model.selection.contains?(target)
          else
            UI.beep
          end
        end
      end

      def onCancel(reason, view)
        Sketchup.active_model.select_tool(nil)
        Sketchup.status_text = ""
        view.tooltip = ""
        view.refresh
      end
    end

  end
end
