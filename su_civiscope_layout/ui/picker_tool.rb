# 编码：UTF-8
module CiviscopeLayout
  module Core
    
    class FunctionPickerTool
      def initialize(mode = 'bldg')
        @mode = mode 
        @state = :pick
        @picked_data = nil
        @filter = CiviscopeLayout::Core.get_picker_filter(mode)
        
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
        @filter = CiviscopeLayout::Core.get_picker_filter(@mode)
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
        
        return unless target

        model = Sketchup.active_model

        if @state == :pick
          # 检查是否点击了BP组本身
          if is_bp_group?(target)
            UI.messagebox("请进入群组再吸取属性")
            return
          end
          
          # 检查是否在BP组内（吸取时必须进入组内）
          if in_bp_group?(target)
            UI.messagebox("请进入群组再吸取属性")
            return
          end
          
          # 检查类型匹配
          target_type = get_entity_type(target)
          if target_type && target_type != @mode
            wrong_type_msg = @mode == 'bldg' ? 
              "您选择的是建筑属性刷，请点击CIM建筑吸取属性" :
              "您选择的是地块属性刷，请点击CIM地块吸取属性"
            UI.messagebox(wrong_type_msg)
            return
          end
          
          # 吸取属性
          if target.get_attribute("dynamic_attributes", "#{@mode}_func")
            @picked_data = pick_attributes(target)
            @state = :paint
            update_status
            view.refresh
          else
            UI.beep
          end

        elsif @state == :paint
          # 检查是否点击了BP组本身
          if is_bp_group?(target)
            UI.messagebox("请进入群组后再刷属性")
            return
          end
          
          # 检查是否在BP组内（应用时需要进入组内）
          if in_bp_group?(target)
            UI.messagebox("请进入群组后再刷属性")
            return
          end
          
          # 检查类型匹配
          target_type = get_entity_type(target)
          if target_type && target_type != @mode
            wrong_type_msg = @mode == 'bldg' ? 
              "您选择的是建筑属性刷，请点击CIM建筑吸取属性" :
              "您选择的是地块属性刷，请点击CIM地块吸取属性"
            UI.messagebox(wrong_type_msg)
            return
          end
          
          # 应用属性
          if target.get_attribute("dynamic_attributes", "#{@mode}_func")
            model.start_operation("属性刷:赋予#{@mode == 'bldg' ? '建筑' : '地块'}功能", true)
            apply_attributes(target)
            
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

      private

      # 判断实体是否是BP组本身
      def is_bp_group?(entity)
        # 只有Group或ComponentInstance才可能是BP组
        return false unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
        
        # BP组本身没有CIM属性
        return false if entity.get_attribute("dynamic_attributes", "bldg_func") ||
                       entity.get_attribute("dynamic_attributes", "site_func")
        
        # BP组内部包含CIM实体
        inner_cim = CiviscopeLayout::Core.collect_cim_entities(entity)
        inner_cim.any?
      end

      # 判断实体类型
      def get_entity_type(entity)
        if entity.get_attribute("dynamic_attributes", "bldg_func")
          return 'bldg'
        elsif entity.get_attribute("dynamic_attributes", "site_func")
          return 'site'
        end
        nil
      end

      # 判断是否在BP组内（用于应用时的检查）
      def in_bp_group?(entity)
        # 检查当前编辑上下文
        model = Sketchup.active_model
        active_entities = model.active_entities
        
        # 如果active_entities是根层级（model.entities），说明用户在BP组外
        # 此时如果用户试图操作组内对象，需要检查是否是BP组
        if active_entities == model.entities
          # 检查entity是否不在根层级（说明它在某个组内）
          if entity.respond_to?(:parent) && entity.parent != model.entities
            # 找到包含该实体的容器（组或组件）
            container = entity.parent.instances.first if entity.parent.is_a?(Sketchup::ComponentDefinition)
            container ||= entity.parent if entity.parent.is_a?(Sketchup::Group)
            
            return false unless container
            
            # 检查容器本身是否是CIM对象（有bldg_func或site_func属性）
            # 如果是CIM对象，则不是BP组
            return false if container.get_attribute("dynamic_attributes", "bldg_func") ||
                           container.get_attribute("dynamic_attributes", "site_func")
            
            # 检查容器内是否包含CIM实体
            inner_cim = CiviscopeLayout::Core.collect_cim_entities(container)
            return inner_cim.any?
          end
        end
        
        false
      end

      # 根据筛选配置吸取属性
      def pick_attributes(entity)
        data = { func: entity.get_attribute("dynamic_attributes", "#{@mode}_func") }
        
        if @mode == 'bldg'
          # 建筑：功能、层高、类型
          data[:floor_height] = entity.get_attribute("dynamic_attributes", "floor_height") if @filter['floor_height']
          data[:bldg_type] = entity.get_attribute("dynamic_attributes", "bldg_type") if @filter['type']
        else
          # 地块：性质、大类、限高
          data[:site_type] = entity.get_attribute("dynamic_attributes", "site_type") if @filter['type']
          data[:height_limit] = entity.get_attribute("dynamic_attributes", "height_limit") if @filter['height_limit']
        end
        
        data
      end

      # 根据筛选配置应用属性
      def apply_attributes(entity)
        # 总是应用功能属性
        entity.set_attribute("dynamic_attributes", "#{@mode}_func", @picked_data[:func])
        
        if @mode == 'bldg'
          # 建筑：功能、层高、类型
          entity.set_attribute("dynamic_attributes", "floor_height", @picked_data[:floor_height]) if @filter['floor_height'] && @picked_data[:floor_height]
          entity.set_attribute("dynamic_attributes", "bldg_type", @picked_data[:bldg_type]) if @filter['type'] && @picked_data[:bldg_type]
        else
          # 地块：性质、大类、限高
          entity.set_attribute("dynamic_attributes", "site_type", @picked_data[:site_type]) if @filter['type'] && @picked_data[:site_type]
          entity.set_attribute("dynamic_attributes", "height_limit", @picked_data[:height_limit]) if @filter['height_limit'] && @picked_data[:height_limit]
        end
      end
    end

  end
end
