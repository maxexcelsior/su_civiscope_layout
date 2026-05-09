# encoding: UTF-8
module CiviscopeLayout
  module Core

    class SetbackTool
      def initialize
        @state = :idle
        @building_type = nil
        @first_run = true
        @dialog = nil
        @face = nil
        @transform = nil
        @edge_group_info = nil
        @temp_text_group = nil
        @temp_text_entities = nil
      end

      def activate
        @state = :idle
        update_status
      end

      def resume(view)
        @state = :idle unless @state == :dialog
        update_status
      end

      def update_status
        case @state
        when :idle
          Sketchup.status_text = "建筑退线工具 | 请选择一个面绘制退线 (点击面或按ESC退出)"
        when :processing
          Sketchup.status_text = "建筑退线工具 | 正在处理退线..."
        when :dialog
          Sketchup.status_text = "建筑退线工具 | 请在对话框中为每条边设定参数"
        end
      end

      def onSetCursor
        UI.set_cursor(6320)
      end

      def onMouseMove(flags, x, y, view)
        return if @state == :processing

        ph = view.pick_helper
        ph.do_pick(x, y)
        picked = ph.best_picked
        face = resolve_face(picked, view, x, y)
        view.tooltip = face ? "点击此面绘制建筑退线" : ""
        view.invalidate
      end

      def onLButtonDown(flags, x, y, view)
        return if @state == :processing || @state == :dialog

        # 首次运行：弹出类型选择
        if @first_run
          @building_type = prompt_building_type
          return unless @building_type  # 用户取消
          @first_run = false
        end

        ph = view.pick_helper
        ph.do_pick(x, y)
        picked = ph.best_picked
        face = resolve_face(picked, view, x, y)

        unless face && face.valid?
          UI.beep
          Sketchup.status_text = "请点击一个面，而不是边或组件"
          return
        end

        @face = face
        @transform = world_transform_for_face(face)
        @edge_group_info = BuildingSetback.get_edge_group_info(@face)

        # 计算边组中点（世界坐标），用于创建临时文字
        midpoints = @edge_group_info.map do |g|
          edges = g[:edges]
          if edges.length == 1
            s = edges[0].start.position.transform(@transform)
            e_pt = edges[0].end.position.transform(@transform)
          else
            s = edges[0].start.position.transform(@transform)
            e_pt = edges[-1].end.position.transform(@transform)
          end
          Geom::Point3d.new((s.x + e_pt.x) * 0.5, (s.y + e_pt.y) * 0.5, (s.z + e_pt.z) * 0.5)
        end

        # 创建临时文字实体（始终可见，不受对话框遮挡影响）
        model = Sketchup.active_model
        @temp_text_group = model.entities.add_group
        @temp_text_entities = midpoints.map do |pt|
          offset_pt = Geom::Point3d.new(pt.x + 0.5.m, pt.y + 0.5.m, pt.z + 0.5.m)
          @temp_text_group.entities.add_text("15", offset_pt)
        end

        show_setback_dialog(view)
      end

      def onCancel(reason, view)
        # 关闭对话框（如有）
        if @dialog
          @dialog.close
          @dialog = nil
        end
        # 清理临时文字
        erase_temp_text
        @face = nil
        @transform = nil
        Sketchup.active_model.select_tool(nil)
        Sketchup.status_text = ""
        view.tooltip = ""
        view.refresh
      end

      private

      # 弹出建筑类型选择对话框（使用数字选择，避免 SketchUp 下拉列表兼容性问题）
      # 返回值: :civil / :old_city / :industrial，取消返回 nil
      def prompt_building_type
        prompts = [
          "请选择地区类型，输入数字后确认:\n",
          "  1 = 旧城区",
          "  2 = 其他地区-民用建筑",
          "  3 = 其他地区-工业建筑"
        ]
        result = UI.inputbox([prompts.join("\n")], ["2"], "建筑退线设置")
        return nil if result == false

        case result[0].to_i
        when 1 then :old_city
        when 3 then :industrial
        else :civil
        end
      end

      # 从点击拾取中解析出面对象
      def resolve_face(picked, view, x, y)
        return picked if picked.is_a?(Sketchup::Face)

        if picked.is_a?(Sketchup::Edge)
          f = picked.faces.first
          return f if f
        end

        ph = view.pick_helper
        ph.do_pick(x, y)
        ph.all_picked.each { |e| return e if e.is_a?(Sketchup::Face) }
        nil
      end

      # 获取面所在容器的世界变换
      def world_transform_for_face(face)
        parent = face.parent
        return Geom::Transformation.new if parent.is_a?(Sketchup::Model)

        inst = parent.instances.first
        return Geom::Transformation.new unless inst

        CiviscopeLayout::Core.get_full_world_transform(inst)
      end

      # 高亮指定的边组
      def highlight_edge_group(index)
        return unless @edge_group_info && index >= 0 && index < @edge_group_info.length
        model = Sketchup.active_model
        model.selection.clear
        @edge_group_info[index][:edges].each { |e| model.selection.add(e) }
      end

      # 删除临时文字实体
      def erase_temp_text
        if @temp_text_group && @temp_text_group.valid?
          @temp_text_group.erase!
        end
        @temp_text_group = nil
        @temp_text_entities = nil
      end

      # 创建并显示边参数设置对话框
      def show_setback_dialog(view)
        @state = :dialog
        update_status

        @dialog = UI::HtmlDialog.new({
          dialog_title: "建筑退线设置",
          width: 420,
          height: 460,
          resizable: false,
          style: UI::HtmlDialog::STYLE_DIALOG
        })

        html_path = File.join(__dir__, '..', 'ui', 'ui_setback.html')
        @dialog.set_file(html_path)

        # Ruby → JS：推送边组标签数据
        @dialog.add_action_callback("ready") do |_|
          labels = BuildingSetback.get_edge_group_info(@face).map { |g| g[:label] }
          @dialog.execute_script("setData(#{labels.to_json})")
        end

        # JS → Ruby：同步所有边的当前值（用于文字显示）和高亮当前边组
        @dialog.add_action_callback("sync_values") do |_, json|
          data = JSON.parse(json)
          edges_data = data["edges"]
          idx = data["currentIndex"].to_i

          # 更新临时文字
          if @temp_text_entities
            edges_data.each_with_index do |ed, i|
              next unless @temp_text_entities[i] && @temp_text_entities[i].valid?
              text = if ed["isWater"]
                       "⛵水"
                     elsif ed["isGreen"]
                       "🌳绿#{ed["greenWidth"]}"
                     else
                       ed["roadWidth"].to_s
                     end
              @temp_text_entities[i].text = text
            end
          end

          # 高亮当前边组
          highlight_edge_group(idx)
        end

        # JS → Ruby：用户点击"生成退线"
        @dialog.add_action_callback("generate_setbacks") do |_, json|
          data = JSON.parse(json)

          # 在 dialog.close 触发 set_on_closed 清空前，保存所需数据到局部变量
          face = @face
          transform = @transform
          bldg_type = @building_type

          @dialog.close
          @dialog = nil

          # 清理临时文字
          erase_temp_text

          model = Sketchup.active_model
          model.selection.clear

          @state = :processing
          update_status

          # 将结构化边数据转换为距离哈希
          edge_distances_m = data["edges"].map do |ed|
            if ed["isWater"]
              # 相邻水域：使用固定退线距离
              BuildingSetback.get_water_green_setback(bldg_type)
            elsif ed["isGreen"]
              road_w = ed["roadWidth"].to_f
              green_w = ed["greenWidth"].to_f
              road_setback = BuildingSetback.get_setback_distances(road_w, bldg_type)
              if green_w >= road_setback[:low]
                # 绿地宽度大于等于道路退线要求时，退线距离=10
                { low: 10.0, mid: 10.0, high: 10.0 }
              else
                # 绿地宽度小于道路退线要求，道路退线减去绿地宽度
                {
                  low:  road_setback[:low]  - green_w,
                  mid:  road_setback[:mid]  - green_w,
                  high: road_setback[:high] - green_w
                }
              end
            else
              # 相邻道路：按道路宽度计算退线
              BuildingSetback.get_setback_distances(ed["roadWidth"].to_f, bldg_type)
            end
          end

          # 调用退线计算与绘制
          BuildingSetback.process_face(face, transform, bldg_type, edge_distances_m)

          # 清理
          @face = nil
          @transform = nil
          @edge_group_info = nil
          @state = :idle
          update_status
          view.refresh
        end

        @dialog.set_on_closed do
          @dialog = nil
          erase_temp_text
          @face = nil
          @transform = nil
          @edge_group_info = nil
          model = Sketchup.active_model
          model.selection.clear if model
          @state = :idle
          update_status
          view.refresh if view
        end

        @dialog.show
      end
    end

  end
end
